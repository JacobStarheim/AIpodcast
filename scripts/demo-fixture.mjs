import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
export const demoDirectory = join(repositoryRoot, ".local", "demo");
export const demoTitle = "Aurora research voyage — local smoke test";
export const demoGuid = "aipodcast-local-aurora-v1";
export const demoSourceName = "AIpodcast local demo";
export const questionText = "How many sensors does the research ship Aurora carry?";
export const unsupportedQuestion =
  "What is the name of the captain of the research ship Aurora?";

// Keep the known facts in spoken audio. Ingest must discover them through the real
// transcription pipeline; the harness never inserts transcript or embedding data.
const episodeText = `Welcome to the Aurora research voyage podcast.
Today we are sharing the plan for a small ocean research mission.
The research ship Aurora carries twenty four sensors.
Those twenty four sensors measure the temperature of the sea.
The ship leaves the port of Tromso on Tuesday morning.
The voyage lasts three days, and the crew will collect measurements each hour.
On the first day, the team checks every sensor and records a starting temperature.
On the second day, they compare measurements from shallow and deep water.
On the final day, they return to the same port with their results.
To recap, Aurora carries twenty four sensors, departs from Tromso on Tuesday,
and spends three days at sea. Thank you for listening.`;

function run(command, args) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 120_000
    });
  } catch (error) {
    const detail = error.stderr?.toString().trim();
    throw new Error(
      `Could not run ${command}. Install macOS speech tools and ffmpeg/ffprobe.` +
      (detail ? ` ${detail}` : ""),
      { cause: error }
    );
  }
}

export function audioDuration(path) {
  const duration = Number(run(process.env.FFPROBE_PATH || "ffprobe", [
    "-v", "error", "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1", path
  ]).trim());
  if (!Number.isFinite(duration) || duration <= 0) {
    throw new Error(`Audio has no valid duration: ${path}`);
  }
  return duration;
}

export async function prepareDemoFixture() {
  await mkdir(demoDirectory, { recursive: true });
  const voice = process.env.DEMO_VOICE || "Samantha";
  const fingerprint = createHash("sha256")
    .update(JSON.stringify({ episodeText, questionText, voice, rate: 145, version: 1 }))
    .digest("hex");
  const episodePath = join(demoDirectory, "aurora.mp3");
  const questionPath = join(demoDirectory, "question.wav");
  const manifestPath = join(demoDirectory, "manifest.json");
  try {
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    if (manifest.fingerprint === fingerprint) {
      const durationSec = audioDuration(episodePath);
      audioDuration(questionPath);
      if (durationSec >= 40 && durationSec <= 70) {
        return { ...manifest, episodePath, questionPath };
      }
    }
  } catch {
    // Missing, stale, or invalid local generated assets are safe to regenerate.
  }

  const speechPath = join(demoDirectory, "episode.txt");
  const spokenQuestionPath = join(demoDirectory, "question.txt");
  await writeFile(speechPath, episodeText);
  await writeFile(spokenQuestionPath, questionText);
  run("say", ["-v", voice, "-r", "145", "-f", speechPath,
    "-o", join(demoDirectory, "episode.aiff")]);
  run(process.env.FFMPEG_PATH || "ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-i", join(demoDirectory, "episode.aiff"),
    "-ar", "24000", "-ac", "1", "-codec:a", "libmp3lame", "-b:a", "64k",
    episodePath
  ]);
  run("say", ["-v", voice, "-r", "145", "-f", spokenQuestionPath,
    "-o", join(demoDirectory, "question.aiff")]);
  run(process.env.FFMPEG_PATH || "ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-i", join(demoDirectory, "question.aiff"),
    "-ar", "24000", "-ac", "1", "-codec:a", "pcm_s16le", questionPath
  ]);
  const durationSec = audioDuration(episodePath);
  const questionDurationSec = audioDuration(questionPath);
  if (durationSec < 40 || durationSec > 70) {
    throw new Error(`Fixture must last 40–70 seconds; generated ${durationSec.toFixed(1)} seconds.`);
  }
  const manifest = {
    fingerprint, title: demoTitle, guid: demoGuid,
    durationSec, questionDurationSec, questionText, unsupportedQuestion
  };
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  return { ...manifest, episodePath, questionPath };
}

export function assertLoopbackUrl(value, label) {
  const url = new URL(value);
  if (url.protocol !== "http:" ||
      !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) ||
      url.username || url.password || url.search || url.hash ||
      !["", "/"].includes(url.pathname)) {
    throw new Error(`${label} must be a plain local HTTP origin, such as http://127.0.0.1:4000.`);
  }
  return url.origin;
}

export function escapeXml(text) {
  return String(text).replace(/[<>&"']/g, (char) => ({
    "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;"
  })[char]);
}
