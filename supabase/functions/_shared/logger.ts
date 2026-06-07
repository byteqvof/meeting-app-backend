type LogLevel = "info" | "warn" | "error";

type LogFields = Record<string, unknown>;

export interface RequestLogger {
  requestId: string;
  startedAt: number;
  info: (event: string, fields?: LogFields) => void;
  warn: (event: string, fields?: LogFields) => void;
  error: (event: string, fields?: LogFields) => void;
}

function emit(
  level: LogLevel,
  functionName: string,
  requestId: string,
  startedAt: number,
  event: string,
  fields: LogFields = {},
): void {
  const payload = {
    level,
    function: functionName,
    request_id: requestId,
    event,
    elapsed_ms: Date.now() - startedAt,
    ...fields,
  };

  const message = JSON.stringify(payload);

  if (level === "error") {
    console.error(message);
    return;
  }

  if (level === "warn") {
    console.warn(message);
    return;
  }

  console.info(message);
}

export function createRequestLogger(
  functionName: string,
  req: Request,
): RequestLogger {
  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
  const startedAt = Date.now();

  return {
    requestId,
    startedAt,
    info: (event, fields) =>
      emit("info", functionName, requestId, startedAt, event, fields),
    warn: (event, fields) =>
      emit("warn", functionName, requestId, startedAt, event, fields),
    error: (event, fields) =>
      emit("error", functionName, requestId, startedAt, event, fields),
  };
}

export function errorFields(error: unknown): LogFields {
  if (error instanceof Error) {
    return {
      error_name: error.name,
      error_message: error.message,
      error_stack: error.stack,
    };
  }

  if (typeof error === "object" && error !== null) {
    return { error };
  }

  return { error_message: String(error) };
}

export function roundCoordinate(value: number): number {
  return Math.round(value * 1000) / 1000;
}
