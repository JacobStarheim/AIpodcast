import { createServer } from "node:http";
import { loadConfig } from "./config.js";
import { createPool } from "./db.js";
import { OpenAiClient } from "./ai-client.js";
import { PostgresRepository } from "./repository.js";
import { createApp } from "./app.js";

async function start() {
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  const repository = new PostgresRepository(pool);
  const aiClient = new OpenAiClient({
    apiKey: config.openAiApiKey,
    transcribeModel: config.transcribeModel,
    embedModel: config.embedModel,
    chatModel: config.chatModel,
    ttsModel: config.ttsModel
  });

  const app = createApp({
    repository,
    aiClient,
    adminKey: config.adminKey,
    minGroundingScore: config.minGroundingScore
  });

  const server = createServer(app);

  server.listen(config.port, () => {
    // eslint-disable-next-line no-console
    console.log(`API listening on http://localhost:${config.port}`);
  });

  async function shutdown(signal: string) {
    // eslint-disable-next-line no-console
    console.log(`Received ${signal}, shutting down API...`);
    server.close(async () => {
      await pool.end();
      process.exit(0);
    });
  }

  process.on("SIGINT", () => {
    void shutdown("SIGINT");
  });
  process.on("SIGTERM", () => {
    void shutdown("SIGTERM");
  });
}

start().catch((error) => {
  // eslint-disable-next-line no-console
  console.error("Failed to start API", error);
  process.exit(1);
});
