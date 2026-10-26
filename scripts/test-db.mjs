import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { defaultDatabaseUrl, migrate } from "./migrate.mjs";

// Runs the *.db.test.ts suites against a throwaway database on the configured
// server. The application database itself is never modified.
const testDatabase = "podcast_ai_test";
const serverUrl = new URL(process.env.TEST_DATABASE_SERVER_URL || defaultDatabaseUrl());
const testUrl = new URL(serverUrl);
testUrl.pathname = `/${testDatabase}`;

const admin = new pg.Client({ connectionString: serverUrl.href, connectionTimeoutMillis: 10_000 });
await admin.connect();
try {
  await admin.query(`DROP DATABASE IF EXISTS ${testDatabase} WITH (FORCE)`);
  await admin.query(`CREATE DATABASE ${testDatabase}`);
} finally {
  await admin.end();
}

await migrate(testUrl.href);
// A second run must be a no-op.
const reapplied = await migrate(testUrl.href, { log: () => {} });
if (reapplied.length > 0) throw new Error(`Migrations were applied twice: ${reapplied.join(", ")}`);

const result = spawnSync("npm", ["test", "--workspaces", "--if-present"], {
  cwd: fileURLToPath(new URL("..", import.meta.url)),
  stdio: "inherit",
  env: { ...process.env, TEST_DATABASE_URL: testUrl.href }
});
process.exitCode = result.status ?? 1;
