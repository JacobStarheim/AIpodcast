import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import dotenv from "dotenv";
import pg from "pg";
import { repositoryRoot } from "../demo-fixture.mjs";

// Asks a fixed set of questions with known answers through the running API
// and scores the answers. Uses real, paid model calls.
//
// Dataset cases (see datasets/*.json):
//   question      text to ask
//   kind          fact | translated | followup | overview | heard | unanswerable
//   history       earlier turns for follow-ups
//   positionSec   playback position for "what did they just say" questions, or
//   positionAfter a phrase; the position becomes the end of the passage saying it
//   scope         "episode" (default) or "library"
//   keywords      groups of alternatives; every group must appear in the answer
//   evidence      phrases that say the answer (any of them); the passages
//                 containing them in the current transcript are the windows a
//                 citation must overlap. Phrases survive re-transcription and
//                 ads that shift times, unlike fixed windows.
//   windows       [[startSec, endSec], ...] fixed alternative to evidence
//   refuse        true when the episode does not contain the answer

const { values: args } = parseArgs({
  options: {
    dataset: { type: "string" },
    only: { type: "string" },
    "top-k": { type: "string" }
  }
});
if (!args.dataset) {
  console.error("Usage: npm run eval -- --dataset scripts/eval/datasets/<name>.json [--only id1,id2] [--top-k n]");
  process.exit(1);
}

const env = { ...dotenv.parse(await readFile(join(repositoryRoot, "apps", "api", ".env"))), ...process.env };
const apiOrigin = env.API_BASE_URL || `http://127.0.0.1:${env.PORT || 4000}`;
const dataset = JSON.parse(await readFile(args.dataset, "utf8"));
const only = args.only ? new Set(args.only.split(",")) : null;

const pool = new pg.Pool({ connectionString: env.DATABASE_URL, max: 1 });
// Read-only lookups: the episode and its transcript for evidence phrases.
const episodeRow = (await pool.query(
  `SELECT e.id, e.transcription_status FROM episodes e JOIN rss_sources s ON s.id = e.source_id
   WHERE e.guid = $1 AND s.rss_url = $2`,
  [dataset.episode.guid, dataset.episode.rssUrl]
)).rows[0];
const transcript = episodeRow
  ? (await pool.query(
      "SELECT start_sec, end_sec, text FROM transcript_segments WHERE episode_id = $1 ORDER BY start_sec",
      [episodeRow.id]
    )).rows.map((row) => ({ startSec: Number(row.start_sec), endSec: Number(row.end_sec), text: matchable(row.text) }))
  : [];
await pool.end();
if (!episodeRow) throw new Error(`Episode ${dataset.episode.guid} is not in the library. Add the feed first.`);
if (episodeRow.transcription_status !== "ready") {
  throw new Error(`Episode is ${episodeRow.transcription_status}; transcribe it before running the eval.`);
}

function matchable(text) {
  return text.toLocaleLowerCase().normalize("NFKC").replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim();
}

/** Windows of the passages (or adjacent pairs) containing any of the phrases. */
function evidenceWindows(phrases) {
  const windows = [];
  for (const phrase of phrases.map(matchable)) {
    transcript.forEach((segment, index) => {
      const next = transcript[index + 1];
      if (segment.text.includes(phrase)) {
        windows.push([segment.startSec, segment.endSec]);
      } else if (next && !next.text.includes(phrase) && `${segment.text} ${next.text}`.includes(phrase)) {
        windows.push([segment.startSec, next.endSec]);
      }
    });
  }
  return windows;
}

function normalize(text) {
  return text.toLocaleLowerCase().normalize("NFKC").replace(/[’']/g, "'");
}

function overlaps([start, end], citation) {
  return citation.startSec < end && citation.endSec > start;
}

async function ask(testCase) {
  let positionSec = testCase.positionSec;
  if (testCase.positionAfter) {
    positionSec = evidenceWindows([testCase.positionAfter])[0]?.[1];
    if (positionSec === undefined) throw new Error(`positionAfter phrase not found: ${testCase.positionAfter}`);
  }
  const body = {
    questionText: testCase.question,
    history: testCase.history ?? [],
    ...(args["top-k"] ? { topK: Number(args["top-k"]) } : {}),
    ...(testCase.scope === "library" ? {} : { episodeId: episodeRow.id }),
    ...(positionSec !== undefined ? { positionSec } : {})
  };
  const startedAt = Date.now();
  const response = await fetch(`${apiOrigin}/v1/qa/answer`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.APP_API_KEY}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(120_000)
  });
  const latencyMs = Date.now() - startedAt;
  const result = await response.json();
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${result.error}`);
  return { result, latencyMs };
}

function score(testCase, result) {
  const answer = normalize(result.answerText);
  if (testCase.refuse) {
    return { pass: !result.grounded, refusedCorrectly: !result.grounded };
  }
  const missing = (testCase.keywords ?? []).filter((group) =>
    !group.some((alternative) => answer.includes(normalize(alternative))));
  const passages = result.citations.filter((citation) => citation.kind === "segment");
  const citationHit = testCase.windows
    ? passages.some((citation) => testCase.windows.some((window) => overlaps(window, citation)))
    : null;
  const answered = result.grounded && missing.length === 0;
  return {
    pass: answered && citationHit !== false,
    answered,
    missingKeywords: missing.map((group) => group.join(" | ")),
    citationHit,
    falseRefusal: !result.grounded
  };
}

const cases = dataset.cases
  .filter((testCase) => !only || only.has(testCase.id))
  .map((testCase) => {
    if (!testCase.evidence) return testCase;
    const windows = evidenceWindows(testCase.evidence);
    if (windows.length === 0) throw new Error(`${testCase.id}: evidence not found in the transcript: ${testCase.evidence.join(" | ")}`);
    return { ...testCase, windows };
  });
const results = [];
for (const testCase of cases) {
  try {
    const { result, latencyMs } = await ask(testCase);
    const verdict = score(testCase, result);
    results.push({ ...testCase, latencyMs, verdict, answer: result.answerText, refusalReason: result.refusalReason,
      citations: result.citations.map((citation) =>
        `${citation.kind}@${Math.round(citation.startSec)}-${Math.round(citation.endSec)}`) });
    const flags = [
      verdict.pass ? "PASS" : "FAIL",
      testCase.kind.padEnd(12),
      `${(latencyMs / 1000).toFixed(1)}s`.padStart(6),
      verdict.citationHit === false ? "wrong-citation" : "",
      verdict.missingKeywords?.length ? `missing: ${verdict.missingKeywords.join(", ")}` : "",
      verdict.falseRefusal ? `refused (${result.refusalReason})` : ""
    ].filter(Boolean);
    console.log(`${testCase.id.padEnd(14)} ${flags.join("  ")}`);
  } catch (error) {
    results.push({ ...testCase, error: error.message, verdict: { pass: false } });
    console.log(`${testCase.id.padEnd(14)} ERROR ${error.message}`);
  }
}

const answerable = results.filter((item) => !item.refuse && !item.error);
const unanswerable = results.filter((item) => item.refuse && !item.error);
const latencies = results.filter((item) => item.latencyMs).map((item) => item.latencyMs).sort((a, b) => a - b);
const percentile = (p) => latencies[Math.min(latencies.length - 1, Math.floor(p * latencies.length))] ?? 0;
const byKind = {};
for (const item of results) {
  byKind[item.kind] ??= { total: 0, passed: 0 };
  byKind[item.kind].total += 1;
  if (item.verdict.pass) byKind[item.kind].passed += 1;
}
const summary = {
  passed: results.filter((item) => item.verdict.pass).length,
  total: results.length,
  answeredCorrectly: `${answerable.filter((item) => item.verdict.answered).length}/${answerable.length}`,
  citationHits: `${answerable.filter((item) => item.verdict.citationHit).length}/${answerable.filter((item) => item.windows).length}`,
  falseRefusals: answerable.filter((item) => item.verdict.falseRefusal).length,
  correctRefusals: `${unanswerable.filter((item) => item.verdict.refusedCorrectly).length}/${unanswerable.length}`,
  latencyP50Ms: percentile(0.5),
  latencyP90Ms: percentile(0.9),
  byKind
};
console.log(JSON.stringify(summary, null, 2));

const reportDirectory = join(repositoryRoot, ".local", "eval");
await mkdir(reportDirectory, { recursive: true });
const reportPath = join(reportDirectory, `${dataset.name}-${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
await writeFile(reportPath, JSON.stringify({ dataset: dataset.name, episodeId: episodeRow.id, summary, results }, null, 2) + "\n");
console.log(`Report: ${reportPath}`);
process.exitCode = summary.passed === summary.total ? 0 : 1;
