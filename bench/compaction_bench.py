#!/usr/bin/env python3
"""
Бенчмарк компакции истории: сравнивает расход prompt-токенов в двух режимах
на ОДНОМ и том же диалоге через реальный API DeepSeek.

  Режим A — без компакции: каждый запрос несёт всю историю целиком.
  Режим B — с компакцией:   системный промпт (+саммари старой части) +
                            последние WINDOW сообщений; каждые WINDOW
                            сообщений за окном сворачиваются в саммари
                            (как ChatViewModel.maybeCompact в приложении).

Замеряет реальные usage.prompt_tokens и честно учитывает накладные на
саммаризацию. ⚠️ Тратит реальные токены (на v4-flash — копейки).

Запуск:
  python3 bench/compaction_bench.py            # 12 ходов, окно 6
  WINDOW=4 TURNS=30 python3 bench/compaction_bench.py

Ключ берётся из ~/.config/manager-assistant/deepseek.key или $DEEPSEEK_API_KEY.
"""
import json, os, urllib.request

def load_key():
    env = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if env:
        return env
    return open(os.path.expanduser("~/.config/manager-assistant/deepseek.key")).read().strip()

KEY = load_key()
URL = "https://api.deepseek.com/chat/completions"
MODEL = os.environ.get("MODEL", "deepseek-chat")
BASE_SYS = "Ты — продуктовый консультант. Отвечай развёрнуто и по делу, 5-7 предложений."
WINDOW = int(os.environ.get("WINDOW", "6"))   # последние N сообщений шлём как есть
TURNS = int(os.environ.get("TURNS", "12"))     # сколько ходов диалога прогнать

def api(messages, max_tokens, temperature=0.3):
    body = {"model": MODEL, "messages": messages, "stream": False,
            "temperature": temperature, "max_tokens": max_tokens}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + KEY})
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.load(r)
    u = d["usage"]
    return d["choices"][0]["message"]["content"], u["prompt_tokens"], u["completion_tokens"]

def sys_with_summary(summary):
    s = BASE_SYS
    if summary:
        s += ("\n\nКраткое содержание более ранней части этого диалога (используй как "
              "контекст, не упоминай его существование):\n" + summary)
    return s

# Вопросы пользователя. Если ходов больше — список зацикливается с пометкой.
USER_TURNS = [
    "Хочу сделать мобильное приложение для бега. С чего начать?",
    "Какие ключевые функции должны быть в MVP?",
    "Как лучше монетизировать такое приложение?",
    "Опиши примерную архитектуру бэкенда.",
    "Какой стек технологий выбрать, чтобы был сразу iOS и Android?",
    "Как реализовать точный GPS-трекинг и при этом экономить батарею?",
    "Какие продуктовые метрики отслеживать после запуска?",
    "Как привлечь первых 1000 пользователей?",
    "Опиши стратегию удержания и работу с оттоком.",
    "Какие юридические моменты учесть при работе с данными о здоровье?",
    "Составь примерный roadmap на первые 6 месяцев.",
    "Подведи итог: ключевые риски проекта и как их снизить.",
]
def user_turn(i):  # i = 1..TURNS
    base = USER_TURNS[(i - 1) % len(USER_TURNS)]
    return base if i <= len(USER_TURNS) else f"(продолжение) {base}"

# --- Фаза 1: реальный прогон БЕЗ компакции (генерируем настоящие ответы) ---
print(f"Фаза 1 — диалог без компакции (полная история), {TURNS} ходов…")
messages = []           # [(role, content)]
A_prompt_total = 0
A_table = []
for i in range(1, TURNS + 1):
    messages.append(("user", user_turn(i)))
    payload = [{"role": "system", "content": BASE_SYS}] + [{"role": r, "content": c} for r, c in messages]
    reply, ptok, ctok = api(payload, max_tokens=350)
    messages.append(("assistant", reply))
    A_prompt_total += ptok
    A_table.append((i, ptok))
    print(f"  ход {i:2}: prompt={ptok:6}  (ответ {ctok} ток.)")

# --- Фаза 2: тот же транскрипт С компакцией ---
print(f"\nФаза 2 — тот же диалог с компакцией (саммари + последние {WINDOW} сообщений)…")
summary = ""
summarized_up_to = 0
B_prompt_total = 0     # токены запросов чата
B_summary_total = 0    # накладные на саммаризацию (тоже платим)
B_table = []
built = []
for i in range(1, TURNS + 1):
    built.append(messages[(i - 1) * 2])           # user-сообщение хода i
    tail = built[summarized_up_to:]
    payload = [{"role": "system", "content": sys_with_summary(summary)}] + \
              [{"role": r, "content": c} for r, c in tail]
    _, ptok, _ = api(payload, max_tokens=1)        # max_tokens=1: меряем только вход
    B_prompt_total += ptok
    B_table.append((i, ptok, summarized_up_to))
    built.append(messages[(i - 1) * 2 + 1])        # assistant-ответ хода i (из фазы 1)
    overflow = len(built) - summarized_up_to - WINDOW
    if overflow >= WINDOW:                          # копим блоками по WINDOW
        block = built[summarized_up_to: summarized_up_to + overflow]
        summ_sys = ("Ты сжимаешь историю диалога. Составь компактное саммари (до ~200 слов): "
                    "сохрани все факты, имена, числа, решения; опусти повторы. Верни ТОЛЬКО текст саммари.")
        txt = ("Текущее саммари (обнови его):\n" + summary + "\n\n" if summary else "") + "Сообщения для сжатия:\n"
        for r, c in block:
            txt += f"[{'Пользователь' if r == 'user' else 'Ассистент'}]: {c}\n"
        new_summary, sp, sc = api(
            [{"role": "system", "content": summ_sys}, {"role": "user", "content": txt}],
            max_tokens=1024, temperature=0.3)
        summary = new_summary
        summarized_up_to += len(block)
        B_summary_total += sp + sc
        print(f"  ход {i:2}: prompt={ptok:6}  → СЖАТО {len(block)} сообщ. (саммари {sp + sc} ток.)")
    else:
        print(f"  ход {i:2}: prompt={ptok:6}")

print("\n================= ИТОГ (накопительно за весь диалог) =================")
print(f"Без компакции:  prompt-токенов всего = {A_prompt_total}")
print(f"С компакцией:   prompt-токенов чата  = {B_prompt_total}")
print(f"                + накладные саммари  = {B_summary_total}")
B_all = B_prompt_total + B_summary_total
print(f"                ИТОГО с компакцией   = {B_all}")
saved = A_prompt_total - B_all
print(f"\nЭкономия prompt-токенов: {saved} ({saved / A_prompt_total * 100:.0f}%)")
print(f"Последний запрос: без компакции {A_table[-1][1]} ток. vs с компакцией {B_table[-1][1]} ток.")
