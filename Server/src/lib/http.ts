/** An error that becomes a JSON response: {"error": {"code", "message"}}. Messages are safe to show. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

const baseHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: baseHeaders });
}

export function noContent(): Response {
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

export function errorResponse(error: ApiError): Response {
  return json({ error: { code: error.code, message: error.message } }, error.status);
}

export const MAX_BODY_BYTES = 512 * 1024;

/** Reads a JSON object body, rejecting oversized or malformed requests. */
export async function readBody(request: Request, maxBytes = MAX_BODY_BYTES): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new ApiError(413, "body_too_large", "The request is too large.");
  const text = await request.text();
  if (text.length > maxBytes) throw new ApiError(413, "body_too_large", "The request is too large.");
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new ApiError(400, "invalid_json", "The request body isn't valid JSON.");
  }
  return object(value, "body");
}

// MARK: - Validation

export function object(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ApiError(400, "invalid_request", `${field} must be an object.`);
  }
  return value as Record<string, unknown>;
}

export function string(
  body: Record<string, unknown>,
  field: string,
  options: { max?: number; pattern?: RegExp } = {},
): string {
  const value = optionalString(body, field, options);
  if (value === undefined || value === "") throw new ApiError(400, "invalid_request", `${field} is required.`);
  return value;
}

export function optionalString(
  body: Record<string, unknown>,
  field: string,
  { max = 4096, pattern }: { max?: number; pattern?: RegExp } = {},
): string | undefined {
  const value = body[field];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string" || value.length > max || (pattern && !pattern.test(value))) {
    throw new ApiError(400, "invalid_request", `${field} is invalid.`);
  }
  return value;
}

/** Validates an IANA time zone name such as "America/Chicago". */
export function timeZone(body: Record<string, unknown>): string | undefined {
  const zone = optionalString(body, "time_zone", { max: 64 });
  if (zone === undefined) return undefined;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return zone;
  } catch {
    throw new ApiError(400, "invalid_request", "time_zone is invalid.");
  }
}
