# manager-agent — сервис-агент рутин (VPS)

Бэкенд для функции «Рутины» в приложении Manager assistant. Работает **24/7** на
VPS под systemd: по расписанию (cron) выполняет заданный промпт через LLM
(DeepSeek), при необходимости собирает данные через **любые MCP-серверы, подключённые
в приложении** (generic, БЕЗ привязки к конкретному MCP), агрегирует результат и
сохраняет его локально (история видна во вкладке «Рутины»). Приложение — тонкий
клиент, который управляет рутинами и читает результаты через REST API.

> Документация для ИИ-агентов и людей. Перед правкой — прочти разделы
> «Безопасность соседства» и «Как расширять».

## Топология (что где)

```
Приложение (macOS) ──HTTPS, Bearer──> Caddy :443 ── /agent/* ──> 127.0.0.1:3100 (этот сервис)
                                          └──────── /mcp,/*  ──> 127.0.0.1:3000 (yougile-mcp.service)
этот сервис ──stdio (npx mcp-remote …)──> MCP-серверы из приложения (generic MCP-хост)
этот сервис ──HTTPS──> api.deepseek.com (LLM)
```

- Слушает строго `127.0.0.1:3100`. Наружу — только через Caddy (`/agent/*`).
- **Источник истины по рутинам** — этот сервис (SQLite). **Источник истины по MCP** —
  приложение: оно присылает список MCP-серверов (`PUT /agent/mcp-servers`), агент
  подключается к ним (stdio) и отдаёт их инструменты рутинам. Никаких привязок к
  конкретному MCP в коде.
- **Единственная панель конфигурации — приложение.** На VPS в env только bootstrap
  (`AGENT_API_TOKEN` + порт + путь к БД). Провайдер/LLM-ключ/модель/таймзона задаются
  из приложения (`PUT /agent/settings`); MCP-серверы — `PUT /agent/mcp-servers`. Секреты
  (LLM-ключ; токены в args/env MCP) на чтение НЕ отдаются (маска/статус).

## Структура

```
src/
  index.ts            boot: env → БД → сервисы → MCP-хост → планировщик → HTTP
  config.ts           bootstrap-env (fail-fast)
  logger.ts           pino + redaction секретов
  domain/             types (контракт с Swift), cron, errors, pricing
  store/              db (SQLite+миграции), routinesRepo, runsRepo, settingsRepo, mcpServersRepo
  settings/           settingsService (маскирование, write-only секреты)
  runner/             mcpHost (generic мульти-MCP), llm (tool-loop), runner (прогон)
  scheduler/          scheduler (croner, overlap-guard, catch-up)
  routines/           routineService (CRUD + валидация + sync с планировщиком)
  http/               app, auth (bearer), schemas, routes.* (вкл. routes.mcp)
test/                 Vitest (без сети/LLM): cron/scheduler/runner/mcpHost/repos/settings/api
deploy/               manager-agent.service, Caddyfile.snippet, *.env.example, deploy.sh
```

## Сборка и тесты (локально)

```bash
npm ci
npm run build        # tsc → dist/
npm test             # Vitest, всё офлайн (заглушки LLM/MCP, :memory: SQLite)
npm run typecheck
```

`agent/` независим от сборки Swift-приложения (SwiftPM видит только `Sources/`/`Tests/`).

## Конфигурация (env, только bootstrap)

`/etc/manager-agent.env` (см. `deploy/manager-agent.env.example`):

| Переменная | Назначение |
|---|---|
| `AGENT_API_TOKEN` | bearer-токен для приложения (обязателен) |
| `AGENT_HOST`/`AGENT_PORT` | где слушать (по умолчанию 127.0.0.1:3100) |
| `AGENT_DB_PATH` | путь к SQLite (по умолчанию /opt/manager-agent/data/agent.db) |
| `AGENT_DEFAULT_TZ` | дефолтная таймзона расписаний (Europe/Moscow) |
| `LOG_LEVEL` | уровень логов |

LLM-ключ/провайдер/YouGile-доступ здесь **отсутствуют** — задаются из приложения.

## REST API

База `https://<domain>/agent`. Все, кроме `/agent/health`, требуют
`Authorization: Bearer <AGENT_API_TOKEN>`. Ошибки — единым форматом
`{ "error": { "code", "message", "details" } }` (коды 400/401/404/409/422/502/500).

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/agent/health` | liveness (без auth) |
| GET | `/agent/settings` | настройки (секрет замаскирован: `hasLlmKey`/`llmKeyHint`) |
| PUT | `/agent/settings` | задать провайдера/модель/таймзону/LLM-ключ |
| GET | `/agent/mcp-servers` | статусы MCP-серверов (БЕЗ секретов: connected/toolCount) |
| PUT | `/agent/mcp-servers` | `{ servers: [...] }` — заменить список (синк из приложения) |
| GET | `/agent/routines` | `{ items: Routine[] }` |
| POST | `/agent/routines` | создать (201) |
| GET | `/agent/routines/:id` | одна рутина |
| PATCH | `/agent/routines/:id` | обновить (тело с `rev`; 409 при устаревшем) |
| DELETE | `/agent/routines/:id` | удалить (204) |
| POST | `/agent/routines/:id/enable` | `{ enabled }` — пауза/возобновление |
| POST | `/agent/routines/:id/trigger` | запустить сейчас (202; заголовок `Idempotency-Key`) |
| GET | `/agent/routines/:id/runs?limit=&cursor=` | история (cursor-пагинация) |
| GET | `/agent/runs/:runId` | полная запись прогона (с `outputMarkdown`) |
| POST | `/agent/chat/ask` | диалог по результату прогона |

Формы тел/ответов — в `src/http/schemas.ts` и `src/domain/types.ts` (этот же контракт
зеркалит Swift `RoutineModels.swift`).

## Деплой на VPS (runbook)

Сервис ставится **строго добавочно** рядом с существующим `yougile-mcp.service`.

```bash
# локально: собрать
npm ci && npm run build

# выложить исходник с dist на VPS (без node_modules/data)
rsync -az --delete --exclude node_modules --exclude data \
  ./ root@<vps>:/opt/manager-agent-src/

# на VPS: установить (идемпотентно)
ssh root@<vps> 'bash /opt/manager-agent-src/deploy/deploy.sh'
```

`deploy.sh`:
1. создаёт системного пользователя `manageragent` и каталоги `/opt/manager-agent{,/data}`;
2. копирует `dist/` + манифесты, ставит prod-зависимости (`npm ci --omit=dev` —
   better-sqlite3 собирается под Node VPS); **`data/` не трогает**;
3. при отсутствии создаёт `/etc/manager-agent.env` со сгенерированным
   `AGENT_API_TOKEN` (печатает его — ввести в приложении); существующий env не перезаписывает;
4. ставит systemd-юнит, `daemon-reload`, `enable --now`;
5. добавляет в Caddyfile маршрут `/agent/* → 127.0.0.1:3100` **только если его нет**
   (бэкап + `caddy validate` + reload); существующий маршрут к MCP не меняет;
6. смоук `curl 127.0.0.1:3100/agent/health`.

Откат маршрута Caddy: восстановить `/etc/caddy/Caddyfile.bak.*` и `systemctl reload caddy`.
БД переживает передеплой (лежит в `/opt/manager-agent/data`).

## Эксплуатация

```bash
systemctl status manager-agent
journalctl -u manager-agent -f         # логи (секреты редактируются pino)
systemctl restart manager-agent        # после правки env; зависшие running примирятся в error
curl -s 127.0.0.1:3100/agent/health
```

Ротация секретов: правим `/etc/manager-agent.env` (только `AGENT_API_TOKEN`) →
`systemctl restart manager-agent` → обновляем токен в приложении. LLM-ключ/YouGile-токен
ротируются из приложения (Настройки агента), без рестарта.

## Передеплой надёжно — грабли и проверка (для агентов в новой сессии)

> Конкретные адрес/домен/токен ЭТОГО инстанса в репозитории НЕТ. Они — в
> `agent/deploy/instance.local.md` (gitignored, см. `instance.example.md`) или спроси у владельца.
> Ниже всё с плейсхолдерами `<vps>` / `<domain>`.

**Грабли, на которые легко наступить (проверено):**
- **scp по паролю флакает.** Если ключ не настроен, перенос молча отваливается, а команда возвращает 0.
  ВСЕГДА проверяй перенос: дождись `100%` в выводе scp ИЛИ сверь размер на VPS
  (`ssh <vps> "wc -c < /tmp/файл"`) ПЕРЕД деплоем.
- **`systemctl restart manager-agent` ВЕШАЕТ ssh-сессию** (на старте сервис ~15с блокируется на подключении
  MCP). Всегда: `systemctl restart --no-block manager-agent`.
- **`npx mcp-remote` требует записываемый HOME/npm-кэш.** Уже задано в юните
  (`Environment=HOME=…`, `npm_config_cache=…`); без этого MCP падает с «Connection closed». Не удалять.
- **После рестарта сервис не слушает ~15с** → `/agent/*` короткое время отдаёт 502; смоук-curl сразу после
  рестарта может ложно упасть (это гонка, не ошибка).
- **Источник правды — репозиторий.** Не оставляй ручную правку `/opt/manager-agent/dist` как «фикс».

**Надёжный передеплой:**
```bash
# локально
cd agent && npm test && npm run build            # тесты зелёные, dist собран
rsync -az --delete --exclude node_modules --exclude data --exclude '*.local.md' \
  ./ root@<vps>:/opt/manager-agent-src/           # (проверь перенос!)
ssh root@<vps> 'bash /opt/manager-agent-src/deploy/deploy.sh'   # идемпотентно
# деплой сам делает restart; если делаешь руками — только: systemctl restart --no-block manager-agent
```
Быстрый путь (если зависимости не менялись): подменить только `dist/` и `systemctl restart --no-block`.

**End-to-end проверка (через публичный `https://<domain>/agent`, bearer-токен из env):**
```bash
BASE=https://<domain>; TOKEN=<agent-api-token>   # токен — из /etc/manager-agent.env
curl -s "$BASE/agent/health"                                            # {"status":"ok",...}
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/agent/settings"        # без секретов (hasLlmKey/llmKeyHint)
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/agent/mcp-servers"     # connected/toolCount, без секретов
# создать рутину → trigger → прочитать прогон, убедиться: реальные tool-calls + чистый outputMarkdown
# ВАЖНО: вывод прогона может содержать control-символы → парсить json.load(..., strict=False)
```

**Ручки качества вывода LLM (куда смотреть при правке раннера):**
- `runner/llm.ts` — на финальной итерации НЕ передавать `tools` (иначе DeepSeek протекает разметкой DSML
  текстом) + `stripModelMarkup`.
- `runner/runner.ts` — `trimLeadingChatter` (срезает преамбулу до первого заголовка).
- Тяжёлые промпты фанятся на 50–80k токенов (детали по каждому элементу) → крутить `maxTokensBudget`
  рутины или упрощать промпт.

## LLM-прокси (/llm → Ollama на VPS)

Локальная LLM для ЧАТА приложения (провайдер «VPS (Ollama)»): Ollama крутится на
этом же VPS и открыта наружу маршрутом Caddy `handle_path /llm/*` с проверкой
`Authorization: Bearer <токен>`. Рутины агента это НЕ трогает — они по-прежнему
ходят в облачный DeepSeek (3–4B модель слабовата для tool-loop, а прогоны на
2 CPU занимали бы десятки минут).

Установка (идемпотентно; повторный запуск печатает тот же токен):

```bash
# модели — аргументами; дефолт: qwen2.5:3b + qwen3:4b-instruct-2507-q4_K_M
sudo bash /opt/manager-agent-src/deploy/install-llm.sh
```

Скрипт: добавляет swap до ≥4 ГБ (`/swapfile-llm`; 3.8 ГБ RAM впритык для 3–4B),
ставит Ollama (bind ТОЛЬКО 127.0.0.1:11434 — проверяется), пишет systemd-override
(`OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=30m`),
генерит токен в `/etc/llm-proxy.token` (0600), вставляет `/llm`-блок в Caddyfile
(бэкап + `caddy validate` + reload; файл получает права root:caddy 0640 — токен
внутри) и пуллит модели. Адрес+токен печатает баннером — ввести в приложении:
⋯ → API-ключи → VPS (Ollama).

Смоук:

```bash
TOKEN=$(cat /etc/llm-proxy.token)
curl -H "Authorization: Bearer $TOKEN" https://<домен>/llm/v1/models   # 200 + список
curl -s -o /dev/null -w '%{http_code}\n' https://<домен>/llm/v1/models # 401
curl https://<домен>/agent/health                                      # 200 (не пострадал)
```

Грабли:
- **deploy.sh может снести /llm-блок**: при ОТСУТСТВИИ `/agent/` в Caddyfile он
  переписывает файл с нуля. Сейчас `/agent/` есть → пропускает; если Caddyfile
  пересоздавался — перезапусти install-llm.sh.
- **Ротация токена**: `rm /etc/llm-proxy.token`, удалить `/llm`-блок из Caddyfile,
  перезапустить install-llm.sh (и обновить токен в приложении).
- **7B на этот VPS не влезает** (Q4-веса ~4.7 ГБ > 3.8 ГБ RAM → swap-инференс
  1–2 ток/с). Реалистично: 3–4B в Q4, ~4–10 ток/с на 2 CPU.
- **Рой в приложении**: `OLLAMA_NUM_PARALLEL=1` сериализует подагентов на сервере —
  для провайдера VPS держи `maxParallelAgents=2` или выключай swarm на тяжёлых
  задачах, иначе хвост волны упрётся в 600-секундный таймаут.
- Модели ставятся/удаляются и из приложения: панель «Локальные модели» → секция
  «VPS (Ollama)» (тот же прокси, стриминг прогресса через `flush_interval -1`).

## Безопасность соседства (НЕ сломать VPN/MCP)

На этом VPS также крутятся: контейнер VPN (Amnezia, docker), x-ui/xray, Caddy и
`yougile-mcp.service`. Правила:
- только новые порты `3100` (агент) и loopback-`11434` (Ollama), юниты
  `manager-agent.service`/`ollama.service`, два новых handle в Caddy (`/agent/*`, `/llm/*`);
- **не трогать** docker/VPN/x-ui/xray, `yougile-mcp.service`, маршрут `/mcp`;
- Caddy не перезапускать жёстко — только `reload`; правки Caddyfile с бэкапом и `validate`;
- сервис слушает loopback; наружу — только через TLS Caddy + bearer.

## Как расширять

- **MCP-инструменты**: ничего в коде не правится — добавь/настрой MCP-сервер в
  ПРИЛОЖЕНИИ (панель MCP), он синхронизируется на агент (`PUT /agent/mcp-servers`),
  и его инструменты станут доступны рутинам. Куда сохранять результат во внешнюю
  систему — пишется в промпте рутины (привязок к конкретному MCP в коде нет).
- **Новый транспорт MCP**: `runner/mcpHost.ts` — добавь коннектор (по умолчанию stdio
  через SDK `StdioClientTransport`); интерфейс `McpHost` не меняется.
- **Новый endpoint**: схема в `schemas.ts` → обработчик в `routes.*` → метод в
  `VPSAgentClient.swift` + DTO + тесты с обеих сторон.
- **Новое поле рутины**: добавь в `domain/types.ts`, миграцию БД (`store/db.ts`,
  новый элемент `MIGRATIONS`, forward-only), маппинг в `routinesRepo`, дефолт в
  `routineService`; в Swift — ленивый декод (`decodeIfPresent`).
- Любые новые статусы прогона/типы — декодировать снисходительно с обеих сторон
  (старые данные и старые клиенты не должны падать).
