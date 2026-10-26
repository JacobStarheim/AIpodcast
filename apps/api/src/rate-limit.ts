import type { NextFunction, Request, Response } from "express";
import type { Pool } from "pg";
import { HttpError } from "./security.js";

export interface RateLimitStore {
  /** Counts one request and returns the count in the current window and when it ends. */
  hit(key: string, windowMs: number): Promise<{ count: number; resetAt: number }>;
}

/** For tests and single-process development. */
export class MemoryRateLimitStore implements RateLimitStore {
  private readonly windows = new Map<string, { count: number; resetAt: number }>();

  constructor(private readonly now: () => number = Date.now) {}

  async hit(key: string, windowMs: number): Promise<{ count: number; resetAt: number }> {
    const now = this.now();
    if (this.windows.size > 10_000) {
      for (const [entryKey, entry] of this.windows) {
        if (entry.resetAt <= now) this.windows.delete(entryKey);
      }
    }
    const windowStart = Math.floor(now / windowMs) * windowMs;
    const id = `${key}@${windowStart}`;
    const entry = this.windows.get(id) ?? { count: 0, resetAt: windowStart + windowMs };
    entry.count += 1;
    this.windows.set(id, entry);
    return { ...entry };
  }
}

/** Counters in PostgreSQL, shared by every API process. */
export class PostgresRateLimitStore implements RateLimitStore {
  constructor(private readonly pool: Pool) {}

  async hit(key: string, windowMs: number): Promise<{ count: number; resetAt: number }> {
    const result = await this.pool.query(
      `INSERT INTO rate_limits (key, window_start, count)
       VALUES ($1, to_timestamp(floor(extract(epoch FROM clock_timestamp()) * 1000 / $2) * $2 / 1000.0), 1)
       ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limits.count + 1
       RETURNING count, extract(epoch FROM window_start) * 1000 AS window_start_ms`,
      [key, windowMs]
    );
    // Old windows are useless; clear them now and then.
    if (Math.random() < 0.01) {
      await this.pool.query(`DELETE FROM rate_limits WHERE window_start < NOW() - INTERVAL '1 day'`);
    }
    const row = result.rows[0];
    return { count: Number(row.count), resetAt: Number(row.window_start_ms) + windowMs };
  }
}

/**
 * Fixed-window limits per signed-in user, or per client address for
 * requests without a user (login).
 */
export class RateLimiter {
  constructor(
    private readonly store: RateLimitStore = new MemoryRateLimitStore(),
    private readonly now: () => number = Date.now
  ) {}

  /** Returns the seconds to wait, or 0 when the request may proceed. */
  async take(key: string, limit: number, windowMs: number): Promise<number> {
    const { count, resetAt } = await this.store.hit(key, windowMs);
    return count > limit ? Math.max(1, Math.ceil((resetAt - this.now()) / 1000)) : 0;
  }

  middleware(name: string, limit: number, windowMs: number) {
    return (req: Request, res: Response, next: NextFunction) => {
      const client = res.locals.user?.id ?? `ip:${req.ip ?? "unknown"}`;
      this.take(`${name}:${client}`, limit, windowMs)
        .then((retryAfter) => next(retryAfter === 0
          ? undefined
          : new HttpError(429, "rate_limited", { "Retry-After": String(retryAfter) })))
        .catch(next);
    };
  }
}
