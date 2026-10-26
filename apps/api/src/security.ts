import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

/** An error whose message is safe to show to the client. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly headers: Record<string, string> = {}
  ) {
    super(message);
  }
}

/** Constant-time comparison that does not leak the expected key's length. */
export function keysMatch(provided: string | undefined, expected: string): boolean {
  if (!provided) return false;
  const digest = (value: string) => createHash("sha256").update(value).digest();
  return timingSafeEqual(digest(provided), digest(expected));
}

export function requestId(req: Request, res: Response, next: NextFunction): void {
  res.locals.requestId = randomUUID();
  res.setHeader("X-Request-Id", res.locals.requestId as string);
  next();
}

export function requireAppKey(appKey: string) {
  return (req: Request, _res: Response, next: NextFunction) => {
    const header = req.header("authorization") ?? "";
    const token = /^Bearer\s+(.+)$/i.exec(header)?.[1]?.trim();
    next(keysMatch(token, appKey) ? undefined : new HttpError(401, "unauthorized"));
  };
}

export function requireAdminKey(adminKey: string) {
  return (req: Request, _res: Response, next: NextFunction) => {
    next(keysMatch(req.header("x-admin-key"), adminKey) ? undefined : new HttpError(401, "unauthorized"));
  };
}

/**
 * Fixed-window limits per client IP, kept in memory. Enough for one API
 * process; several processes would need a shared store.
 */
export class RateLimiter {
  private readonly windows = new Map<string, { count: number; resetAt: number }>();

  constructor(private readonly now: () => number = Date.now) {}

  /** Returns the seconds to wait, or 0 when the request may proceed. */
  take(key: string, limit: number, windowMs: number): number {
    const now = this.now();
    if (this.windows.size > 10_000) {
      for (const [entryKey, entry] of this.windows) {
        if (entry.resetAt <= now) this.windows.delete(entryKey);
      }
    }
    const entry = this.windows.get(key);
    if (!entry || entry.resetAt <= now) {
      this.windows.set(key, { count: 1, resetAt: now + windowMs });
      return 0;
    }
    if (entry.count >= limit) {
      return Math.max(1, Math.ceil((entry.resetAt - now) / 1000));
    }
    entry.count += 1;
    return 0;
  }

  middleware(name: string, limit: number, windowMs: number) {
    return (req: Request, _res: Response, next: NextFunction) => {
      const retryAfter = this.take(`${name}:${req.ip ?? "unknown"}`, limit, windowMs);
      next(retryAfter === 0
        ? undefined
        : new HttpError(429, "rate_limited", { "Retry-After": String(retryAfter) }));
    };
  }
}

/**
 * Client errors keep their message. Anything else is logged with the request
 * id and reported as a generic 500, so upstream and database details stay
 * on the server.
 */
export function errorHandler(logError: (message: string, error: unknown) => void = console.error) {
  return (error: unknown, _req: Request, res: Response, _next: NextFunction) => {
    const id = String(res.locals.requestId ?? "");
    if (error instanceof HttpError) {
      for (const [name, value] of Object.entries(error.headers)) res.setHeader(name, value);
      res.status(error.status).json({ error: error.message });
      return;
    }
    const code = error && typeof error === "object" && "code" in error ? error.code : undefined;
    const type = error && typeof error === "object" && "type" in error ? error.type : undefined;
    if (code === "LIMIT_FILE_SIZE") {
      res.status(413).json({ error: "audio file is too large" });
      return;
    }
    if (type === "entity.parse.failed") {
      res.status(400).json({ error: "invalid JSON body" });
      return;
    }
    if (type === "entity.too.large") {
      res.status(413).json({ error: "request body is too large" });
      return;
    }
    logError(`Request ${id} failed`, error);
    res.status(500).json({ error: "internal_error", requestId: id });
  };
}
