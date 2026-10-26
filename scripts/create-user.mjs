import { randomBytes, scrypt as scryptCallback } from "node:crypto";
import { parseArgs, promisify } from "node:util";
import pg from "pg";
import { defaultDatabaseUrl } from "./migrate.mjs";

// Creates an account directly in the database. The password comes from the
// USER_PASSWORD environment variable so it never appears in shell history.
// The hash format must match apps/api/src/auth.ts.
const scrypt = promisify(scryptCallback);

const { values: args } = parseArgs({
  options: {
    email: { type: "string" },
    name: { type: "string" },
    admin: { type: "boolean", default: false }
  }
});
const password = process.env.USER_PASSWORD ?? "";
if (!args.email || !/^[^\s@]+@[^\s@]+$/.test(args.email) || !args.name) {
  console.error("Usage: USER_PASSWORD=... npm run user:create -- --email you@example.com --name \"Your Name\" [--admin]");
  process.exit(1);
}
if (password.length < 10) {
  console.error("Set USER_PASSWORD to a password of at least 10 characters.");
  process.exit(1);
}

const salt = randomBytes(16);
const N = 16384, r = 8, p = 1;
const key = await scrypt(password, salt, 64, { N, r, p, maxmem: 64 * 1024 * 1024 });
const passwordHash = ["scrypt", N, r, p, salt.toString("base64url"), key.toString("base64url")].join("$");

const client = new pg.Client({ connectionString: defaultDatabaseUrl() });
await client.connect();
try {
  const result = await client.query(
    `INSERT INTO users (email, name, password_hash, role) VALUES ($1, $2, $3, $4) RETURNING id`,
    [args.email, args.name, passwordHash, args.admin ? "admin" : "user"]
  );
  console.log(`Created ${args.admin ? "admin" : "user"} ${args.email} (${result.rows[0].id}).`);
} catch (error) {
  if (error.code === "23505") {
    console.error(`A user with the email ${args.email} already exists.`);
    process.exitCode = 1;
  } else {
    throw error;
  }
} finally {
  await client.end();
}
