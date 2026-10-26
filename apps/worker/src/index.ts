import { loadConfig } from "./config.js";
import { assertSchemaVersion, createPool } from "./db.js";
import { WorkerOpenAiClient } from "./openai-client.js";
import { PostgresWorkerStore } from "./store.js";
import { WorkerService } from "./worker-service.js";

async function main() {
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  await assertSchemaVersion(pool);
  const aiClient = new WorkerOpenAiClient({
    apiKey: config.openAiApiKey,
    transcribeModel: config.transcribeModel,
    embedModel: config.embedModel,
    chatModel: config.chatModel,
    transcribeConcurrency: config.transcribeConcurrency,
    audioChunkOptions: {
      targetChunkSec: config.audioChunkTargetSec,
      ffmpegPath: config.ffmpegPath,
      ffprobePath: config.ffprobePath
    }
  });

  const worker = new WorkerService(new PostgresWorkerStore(pool), aiClient, {
    maxEpisodeAudioMb: config.maxEpisodeAudioMb,
    defaultMaxEpisodesPerSource: config.defaultMaxEpisodesPerSource,
    maxTranscriptionAttempts: config.maxTranscriptionAttempts,
    allowPrivateNetwork: config.allowPrivateNetwork,
    maxChunkSec: config.audioChunkTargetSec * 1.5,
    staleJobSec: config.staleJobSec,
    audioStorageDirectory: config.audioStorageDirectory,
    feedRefreshSec: config.feedRefreshSec,
    dailyTranscriptionSec: config.dailyTranscriptionSec
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
