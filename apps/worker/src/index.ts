import { loadConfig } from "./config.js";
import { createPool } from "./db.js";
import { WorkerOpenAiClient } from "./openai-client.js";
import { WorkerService } from "./worker-service.js";

async function main() {
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  const aiClient = new WorkerOpenAiClient({
    apiKey: config.openAiApiKey,
    transcribeModel: config.transcribeModel,
    embedModel: config.embedModel
  });

  const worker = new WorkerService(pool, aiClient, {
    maxEpisodeAudioMb: config.maxEpisodeAudioMb,
    defaultMaxEpisodesPerSource: config.defaultMaxEpisodesPerSource
  });

  let running = false;

  async function tick() {
    if (running) {
      return;
    }

    running = true;
    try {
      await worker.pollOnce();
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error("Worker tick failed", error);
    } finally {
      running = false;
    }
  }

  await tick();
  const timer = setInterval(() => {
    void tick();
  }, config.pollIntervalMs);

  async function shutdown(signal: string) {
    // eslint-disable-next-line no-console
    console.log(`Received ${signal}, shutting down worker...`);
    clearInterval(timer);
    await pool.end();
    process.exit(0);
  }

  process.on("SIGINT", () => {
    void shutdown("SIGINT");
  });
  process.on("SIGTERM", () => {
    void shutdown("SIGTERM");
  });

  // eslint-disable-next-line no-console
  console.log(`Worker started. Polling every ${config.pollIntervalMs}ms`);
}

main().catch((error) => {
  // eslint-disable-next-line no-console
  console.error("Failed to start worker", error);
  process.exit(1);
});
