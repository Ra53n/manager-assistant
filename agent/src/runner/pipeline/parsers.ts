// parsers.ts — ЧИСТЫЕ функции пайплайна (порт из Swift `PipelinePrompts`, Models.swift
// ~667-802). Без сети и состояния — легко тестируются. Те же форматы маркеров/разделов,
// что в приложении, чтобы поведение совпадало байт-в-байт.

/** Маркер «шаг выполнен» (исполнитель ставит его последней строкой). */
export const NEXT_STEP_MARKER = "NEXT_STEP";
/** Маркер «план непригоден, перепланировать». */
export const REPLAN_MARKER = "REPLAN";
/** Маркер запроса уточнения у пользователя (в headless-движке только как стоп-разделитель). */
export const ASK_USER_MARKER = "ASK_USER";
/** Заголовок раздела зависимостей шагов (для роя). */
export const DEPS_HEADER = "ЗАВИСИМОСТИ";

const STEP_BULLET_RE = /^\s*(\d+[.)]|[-–•*])\s+/;
const DEPS_LINE_RE = /^\s*\d+\s*:/;

/**
 * Текст плана → список шагов: снимает нумерацию/маркеры; пустой план → весь текст одним
 * шагом. Останавливается на разделах ЗАВИСИМОСТИ:/ASK_USER/QUESTION/OPTION.
 */
export function parsePlanSteps(text: string): string[] {
  const steps: string[] = [];
  for (const raw of text.split(/\r?\n/)) {
    let line = raw.trim();
    if (!line) continue;
    const upper = line.toUpperCase();
    if (
      upper.startsWith(DEPS_HEADER) ||
      upper.startsWith(ASK_USER_MARKER) ||
      upper.startsWith("QUESTION:") ||
      upper.startsWith("OPTION:")
    ) {
      break;
    }
    line = line.replace(STEP_BULLET_RE, "").trim();
    const u2 = line.toUpperCase();
    if (u2.includes(NEXT_STEP_MARKER) || u2.includes(REPLAN_MARKER) || u2.includes(ASK_USER_MARKER)) {
      continue;
    }
    if (line) steps.push(line);
  }
  return steps.length > 0 ? steps : [text.trim()];
}

export function wantsNextStep(text: string): boolean {
  return text.toUpperCase().includes(NEXT_STEP_MARKER);
}

export function wantsReplan(text: string): boolean {
  return text.toUpperCase().includes(REPLAN_MARKER);
}

/** Убирает служебные маркеры/разделы из текста перед показом/сохранением. */
export function stripMarkers(text: string): string {
  const kept: string[] = [];
  let inDeps = false;
  for (const line of text.split("\n")) {
    const upper = line.trim().toUpperCase();
    if (upper.startsWith(DEPS_HEADER)) {
      inDeps = true;
      continue;
    }
    if (inDeps) {
      if (DEPS_LINE_RE.test(line)) continue;
      inDeps = false;
    }
    if (upper === ASK_USER_MARKER || upper.startsWith("QUESTION:") || upper.startsWith("OPTION:")) {
      continue;
    }
    kept.push(line);
  }
  let t = kept.join("\n");
  for (const m of [NEXT_STEP_MARKER, REPLAN_MARKER, ASK_USER_MARKER]) {
    t = t.split(m).join("");
  }
  return t.trim();
}

/**
 * Парсит вердикт проверки. true = выполнено. Смотрит ПОСЛЕДНИЙ «ВЕРДИКТ:»; при
 * отсутствии/неоднозначности → true (число повторов ограничено лимитом ретраев).
 */
export function parseVerdict(text: string): boolean {
  const upper = text.toUpperCase();
  const idx = upper.lastIndexOf("ВЕРДИКТ:");
  if (idx >= 0) {
    const tail = upper.slice(idx + "ВЕРДИКТ:".length);
    if (tail.includes("НЕ ВЫПОЛНЕНО")) return false;
    if (tail.includes("ВЫПОЛНЕНО")) return true;
  }
  return true;
}

/**
 * Парсит раздел «ЗАВИСИМОСТИ:» (строки «3: 1,2», номера 1-based) → для каждого шага
 * (0-based) множество индексов-предшественников. Вне диапазона/self/дубли отбрасываются.
 */
export function parseDeps(text: string, stepCount: number): Array<Set<number>> {
  const n = stepCount;
  if (n <= 0) return [];
  const deps: Array<Set<number>> = Array.from({ length: n }, () => new Set<number>());
  let inSection = false;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line.toUpperCase().startsWith(DEPS_HEADER)) {
      inSection = true;
      continue;
    }
    if (!inSection || !line) continue;
    const ci = line.indexOf(":");
    if (ci < 0) continue;
    const stepNum = Number.parseInt(line.slice(0, ci).trim(), 10);
    if (!Number.isInteger(stepNum)) continue;
    const target = stepNum - 1;
    if (target < 0 || target >= n) continue;
    const refs = line
      .slice(ci + 1)
      .split(/[,;\s]+/)
      .filter((s) => s.length > 0);
    for (const r of refs) {
      const num = Number.parseInt(r.trim(), 10);
      if (!Number.isInteger(num)) continue;
      const dep = num - 1;
      if (dep >= 0 && dep < n && dep !== target) deps[target]!.add(dep);
    }
  }
  return deps;
}

/**
 * Волны выполнения (алгоритм Кана): группы индексов шагов, выполнимых параллельно.
 * Цикл/тупик или пустой ввод → последовательный фолбэк (каждый шаг — своя волна).
 */
export function computeWaves(n: number, deps: Array<Set<number>>): number[][] {
  if (n <= 0) return [];
  const d: Array<Set<number>> = Array.from({ length: n }, (_v, i) => {
    const src = i < deps.length ? deps[i]! : new Set<number>();
    return new Set([...src].filter((x) => x >= 0 && x < n && x !== i));
  });
  const placed = new Array<boolean>(n).fill(false);
  const waves: number[][] = [];
  let remaining = n;
  while (remaining > 0) {
    const wave: number[] = [];
    for (let i = 0; i < n; i++) {
      if (placed[i]) continue;
      let ok = true;
      for (const x of d[i]!) {
        if (!placed[x]) {
          ok = false;
          break;
        }
      }
      if (ok) wave.push(i);
    }
    if (wave.length === 0) {
      // цикл/тупик → последовательно (каждый шаг своей волной)
      return Array.from({ length: n }, (_v, i) => [i]);
    }
    for (const i of wave) placed[i] = true;
    remaining -= wave.length;
    waves.push(wave); // wave уже в возрастающем порядке индексов
  }
  return waves;
}
