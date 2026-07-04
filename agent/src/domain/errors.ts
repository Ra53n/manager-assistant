// errors.ts — типизированные ошибки приложения с единым форматом для API.
// HTTP-слой превращает их в `{ error: { code, message, details } }` + статус.

export type ErrorCode =
  | "validation_error"
  | "unauthorized"
  | "not_found"
  | "conflict"
  | "config_error"
  | "upstream_error"
  | "internal";

export class AppError extends Error {
  constructor(
    public readonly code: ErrorCode,
    message: string,
    public readonly httpStatus: number,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = new.target.name;
  }
}

export class ValidationError extends AppError {
  constructor(message: string, details?: unknown) {
    super("validation_error", message, 400, details);
  }
}

export class UnauthorizedError extends AppError {
  constructor(message = "Требуется авторизация") {
    super("unauthorized", message, 401);
  }
}

export class NotFoundError extends AppError {
  constructor(message = "Не найдено") {
    super("not_found", message, 404);
  }
}

export class ConflictError extends AppError {
  constructor(message = "Конфликт версий (устаревший rev)", details?: unknown) {
    super("conflict", message, 409, details);
  }
}

export class UpstreamError extends AppError {
  constructor(message: string, details?: unknown) {
    super("upstream_error", message, 502, details);
  }
}
