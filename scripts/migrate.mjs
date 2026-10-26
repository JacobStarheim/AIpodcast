import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import dotenv from "dotenv";
import pg from "pg";

const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
export const migrationsDirectory = join(repositoryRoot, "infrastructure", "migrations");

export function migrationFiles() {
  return readdirSync(migrationsDirectory)
    .filter((name) => /^\d{3}_[\w-]+\.sql$/.test(name))
    .sort()
    .map((name) => ({ version: name.slice(0, 3), name, path: join(migrationsDirectory, name) }));
}

export function defaultDatabaseUrl() {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  try {
    const env = dotenv.parse(readFileSync(join(repositoryRoot, "apps", "api", ".env")));
    if (env.DATABASE_URL) return env.DATABASE_URL;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return "postgresql://podcast:podcast@localhost:5432/podcast_ai";
}

// A freshly created container can report healthy while initdb still restarts
// the server, so retry briefly instead of failing `npm run db:up`.
async function connectWithRetry(connectionString, deadlineMs = 30_000) {
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    const client = new pg.Client({ connectionString, connectionTimeoutMillis: 5_000 });
    try {
      await client.connect();
      return client;
    } catch (error) {
      await client.end().catch(() => {});
      if (Date.now() > deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
  }
}

/** Applies each pending migration in its own transaction. Safe to run repeatedly. */
export async function migrate(connectionString, { log = console.log } = {}) {
  const client = await connectWithRetry(connectionString);
  try {
    await client.query("SELECT pg_advisory_lock(hashtext('podcast_ai_migrations'))");
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      version TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )`);
    const applied = new Set(
      (await client.query("SELECT version FROM schema_migrations")).rows.map((row) => row.version)
    );
    const pending = migrationFiles().filter((migration) => !applied.has(migration.version));
    for (const migration of pending) {
      await client.query("BEGIN");
      try {
        await client.query(readFileSync(migration.path, "utf8"));
        await client.query("INSERT INTO schema_migrations (version, name) VALUES ($1, $2)", [
          migration.version,
          migration.name
        ]);
        await client.query("COMMIT");
      } catch (error) {
        await client.query("ROLLBACK");
        throw new Error(`Migration ${migration.name} failed: ${error.message}`);
      }
      log(`Applied ${migration.name}`);
    }
    if (pending.length === 0) log("Database schema is up to date.");
    return pending.map((migration) => migration.name);
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  migrate(defaultDatabaseUrl()).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
