import { Pool } from "pg";

export function createPool(databaseUrl: string): Pool {
  return new Pool({
    connectionString: databaseUrl,
    max: 12,
    idleTimeoutMillis: 30_000
  });
}
