import { SCHEMA_VERSION } from "@podcast/shared-types";
import { Pool } from "pg";

export function createPool(databaseUrl: string): Pool {
  return new Pool({
    connectionString: databaseUrl,
    max: 12,
    idleTimeoutMillis: 30_000
  });
}

/** Fails fast with a clear message instead of SQL errors on an old schema. */
export async function assertSchemaVersion(pool: Pool): Promise<void> {
  const result = await pool
    .query<{ version: string | null }>("SELECT MAX(version) AS version FROM schema_migrations")
    .catch(() => ({ rows: [{ version: null }] }));
  const version = result.rows[0]?.version ?? null;
  if (version !== SCHEMA_VERSION) {
    throw new Error(
      `Database schema is ${version ?? "not migrated"}, expected ${SCHEMA_VERSION}. Run npm run db:migrate.`
    );
  }
}
