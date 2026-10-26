import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assertSchemaVersion } from "../src/db.js";
import { PostgresRepository } from "../src/repository.js";

// Runs against a real, migrated database: `npm run test:db` from the repository root.
const databaseUrl = process.env.TEST_DATABASE_URL;

function vector(seed: number): string {
  return `[${Array.from({ length: 1536 }, (_, index) => (index === seed ? 1 : 0)).join(",")}]`;
}

describe.runIf(databaseUrl)("PostgresRepository against PostgreSQL", () => {
  let pool: pg.Pool;
  let repository: PostgresRepository;
  let sourceId: string;
  let readyId: string;
  let otherReadyId: string;
  let pendingId: string;

  beforeAll(async () => {
    pool = new pg.Pool({ connectionString: databaseUrl, max: 4 });
    repository = new PostgresRepository(pool);
    await assertSchemaVersion(pool);
  });

  afterAll(async () => {
    await pool.end();
  });

  beforeEach(async () => {
    await pool.query("TRUNCATE rss_sources, episodes, transcript_segments, episode_chapters, ingest_jobs, qa_events CASCADE");
    sourceId = (await pool.query(
      `INSERT INTO rss_sources (name, rss_url, image_url, language)
       VALUES ('Show', 'https://feeds.test/show', 'https://cdn.test/show.jpg', 'en') RETURNING id`
    )).rows[0].id;
    const insertEpisode = async (guid: string, status: string, day: number, extra = "") => (await pool.query(
      `INSERT INTO episodes (source_id, guid, title, description, published_at, audio_url, transcription_status,
                             transcription_error ${extra ? ", summary, language" : ""})
       VALUES ($1, $2, $3, 'About 50% of_listeners', $4, 'https://cdn.test/a.mp3', $5, 'Upstream down'
               ${extra ? ", 'Summary.', 'nb'" : ""})
       RETURNING id`,
      [sourceId, guid, `Episode ${guid}`, new Date(Date.UTC(2026, 0, day)), status]
    )).rows[0].id as string;
    readyId = await insertEpisode("ready", "ready", 3, "with summary");
    otherReadyId = await insertEpisode("other", "ready", 2);
    pendingId = await insertEpisode("pending", "failed", 1);

    // Many decoy rows from another episode, so a filtered HNSW search has to
    // keep scanning to find the target episode's passages.
    await pool.query(
      `INSERT INTO transcript_segments (episode_id, start_sec, end_sec, text, embedding)
       SELECT $1, n * 20, n * 20 + 20, 'Decoy passage ' || n, $2::vector
       FROM generate_series(0, 299) AS n`,
      [otherReadyId, vector(0)]
    );
    await pool.query(
      `INSERT INTO transcript_segments (episode_id, start_sec, end_sec, text, embedding) VALUES
         ($1, 0, 20, 'Aurora carries twenty four sensors', $2::vector),
         ($1, 20, 40, 'The ship leaves Tromso on Tuesday', $3::vector),
         ($1, 40, 60, 'Thanks for listening', $4::vector)`,
      [readyId, vector(1), vector(2), vector(3)]
    );
    await pool.query(
      `INSERT INTO episode_chapters (episode_id, position, start_sec, end_sec, title, summary, embedding) VALUES
         ($1, 0, 0, 40, 'Voyage', 'The plan.', $2::vector),
         ($1, 1, 40, 60, 'Outro', 'Goodbye.', $3::vector)`,
      [readyId, vector(5), vector(6)]
    );
  });

  it("lists episodes with filters, artwork fallback and failure reasons", async () => {
    const all = await repository.listEpisodes({ limit: 10 });
    expect(all.items.map((item) => item.title)).toEqual(["Episode ready", "Episode other", "Episode pending"]);
    expect(all.items[0]).toMatchObject({ imageUrl: "https://cdn.test/show.jpg", transcriptionError: null });
    expect(all.items[2]).toMatchObject({ transcriptionStatus: "failed", transcriptionError: "Upstream down" });

    const ready = await repository.listEpisodes({ limit: 10, statuses: ["ready"] });
    expect(ready.items).toHaveLength(2);

    // % and _ are matched literally.
    expect((await repository.listEpisodes({ limit: 10, q: "50%" })).items).toHaveLength(3);
    expect((await repository.listEpisodes({ limit: 10, q: "0%" })).items).toHaveLength(3);
    expect((await repository.listEpisodes({ limit: 10, q: "5_%" })).items).toHaveLength(0);

    const first = await repository.listEpisodes({ limit: 2 });
    expect(first.nextCursor).not.toBeNull();
    const second = await repository.listEpisodes({ limit: 2, cursor: first.nextCursor! });
    expect(second.items.map((item) => item.title)).toEqual(["Episode pending"]);
    await expect(repository.listEpisodes({ limit: 2, cursor: "garbage" })).rejects.toThrow("Invalid cursor");
  });

  it("returns episode details with summary, language and chapters", async () => {
    const detail = await repository.getEpisodeById(readyId);
    expect(detail).toMatchObject({
      summary: "Summary.",
      language: "nb",
      chapters: [
        expect.objectContaining({ title: "Voyage", startSec: 0, endSec: 40 }),
        expect.objectContaining({ title: "Outro", startSec: 40, endSec: 60 })
      ]
    });
    expect((await repository.getEpisodeById(otherReadyId))?.language).toBe("en");
    expect(await repository.listReadyLanguages()).toEqual(["en", "nb"]);
  });

  it("finds an episode's passages with a filtered vector search", async () => {
    const results = await repository.searchSegments({
      embedding: JSON.parse(vector(2)), episodeId: readyId, topK: 3
    });
    expect(results.map((result) => result.text)).toEqual([
      "The ship leaves Tromso on Tuesday",
      "Aurora carries twenty four sensors",
      "Thanks for listening"
    ]);
    expect(results[0]?.score).toBeCloseTo(1, 5);
    expect(results[0]?.kind).toBe("segment");
  });

  it("finds passages by keyword, by time and chapters by meaning", async () => {
    const keyword = await repository.searchSegmentsByText({ terms: ["tromso", "tuesday", "zebra"], episodeId: readyId, topK: 5 });
    expect(keyword.map((result) => result.text)).toEqual(["The ship leaves Tromso on Tuesday"]);

    const heard = await repository.segmentsBetween({ episodeId: readyId, fromSec: 25, toSec: 45, limit: 6 });
    expect(heard.map((result) => result.startSec)).toEqual([20, 40]);

    const chapters = await repository.searchChapters({ embedding: JSON.parse(vector(6)), topK: 1 });
    expect(chapters).toEqual([expect.objectContaining({
      kind: "chapter", episodeId: readyId, startSec: 40, text: "Outro: Goodbye."
    })]);
    expect(chapters[0]?.segmentId).toMatch(/^chapter:/);
  });

  it("adds the passages around each hit, once, in order", async () => {
    const hits = await repository.searchSegments({ embedding: JSON.parse(vector(2)), episodeId: readyId, topK: 1 });
    expect(hits.map((hit) => hit.startSec)).toEqual([20]);
    const expanded = await repository.withNeighbours([...hits, { ...hits[0]!, segmentId: "dup" }]);
    expect(expanded.map((segment) => segment.startSec)).toEqual([0, 20, 40]);
    expect(expanded.find((segment) => segment.startSec === 20)?.score).toBeCloseTo(1, 5);
    expect(expanded.find((segment) => segment.startSec === 0)?.score).toBe(0);
  });

  it("adds a feed once, queues one import, and reports it", async () => {
    const first = await repository.addSource({ name: "", rssUrl: "https://feeds.test/new", imageUrl: null });
    expect(first.created).toBe(true);
    expect(first.source).toMatchObject({ name: "feeds.test", episodeCount: 0, lastJob: { status: "queued" } });

    const again = await repository.addSource({ name: "Other name", rssUrl: "https://feeds.test/new", imageUrl: null });
    expect(again).toMatchObject({ created: false, source: { id: first.source.id } });
    const jobs = await pool.query("SELECT max_episodes_per_source FROM ingest_jobs WHERE source_id = $1", [first.source.id]);
    expect(jobs.rows).toEqual([{ max_episodes_per_source: 0 }]);

    const sources = await repository.listSources();
    expect(sources.map((source) => source.rssUrl)).toEqual(["https://feeds.test/new", "https://feeds.test/show"]);
    expect(sources[1]).toMatchObject({ episodeCount: 3, readyEpisodeCount: 2, lastJob: null });
  });

  it("queues a single episode once and ignores ready ones", async () => {
    const queued = await repository.requestTranscription(pendingId);
    expect(queued?.jobId).toEqual(expect.any(String));
    expect(queued?.episode).toMatchObject({ transcriptionStatus: "queued", transcriptionError: null });

    expect((await repository.requestTranscription(pendingId))?.jobId).toBeNull();
    expect((await repository.requestTranscription(readyId))?.jobId).toBeNull();
    expect(await repository.requestTranscription("44444444-4444-4444-8444-444444444444")).toBeNull();

    const job = await pool.query("SELECT source_id, episode_id, status FROM ingest_jobs");
    expect(job.rows).toEqual([{ source_id: sourceId, episode_id: pendingId, status: "queued" }]);
    // Episode jobs do not count as the source's latest import.
    expect((await repository.listSources())[0]?.lastJob).toBeNull();
  });
});
