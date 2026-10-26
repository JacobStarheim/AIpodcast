import { describe, expect, it } from "vitest";
import { buildTranscriptPrompt, parseSummaryPayload } from "../src/summarize.js";
import { mapWithConcurrency } from "../src/concurrency.js";

const segments = [
  { startSec: 0, endSec: 20, text: "Welcome to the show." },
  { startSec: 20, endSec: 40, text: "Sensors on the ship." },
  { startSec: 40, endSec: 61, text: "Returning to port." }
];

describe("parseSummaryPayload", () => {
  it("turns passage indices into chapter times", () => {
    const result = parseSummaryPayload(JSON.stringify({
      language: "en",
      summary: "  A voyage.  ",
      chapters: [
        { title: "Return", summary: "Back to port.", startIndex: 2 },
        { title: "Intro", summary: "Hello.", startIndex: 1 },
        { title: "Duplicate", summary: "", startIndex: 2 },
        { title: "Out of range", summary: "", startIndex: 9 }
      ]
    }), segments, 61);

    expect(result).toEqual({
      language: "en",
      summary: "A voyage.",
      chapters: [
        { title: "Intro", summary: "Hello.", startSec: 0, endSec: 40 },
        { title: "Return", summary: "Back to port.", startSec: 40, endSec: 61 }
      ]
    });
  });

  it("rejects output without a summary or valid chapters", () => {
    expect(() => parseSummaryPayload(JSON.stringify({ language: "en", summary: "", chapters: [] }), segments, 61))
      .toThrow("Summary was empty");
    expect(() => parseSummaryPayload(JSON.stringify({
      language: "en", summary: "Ok", chapters: [{ title: "", summary: "", startIndex: 0 }]
    }), segments, 61)).toThrow("no valid chapters");
  });

  it("drops a language that is not a language tag", () => {
    const result = parseSummaryPayload(JSON.stringify({
      language: "Norwegian", summary: "Ok", chapters: [{ title: "All", summary: "", startIndex: 0 }]
    }), segments, 61);
    expect(result.language).toBeNull();
  });
});

describe("buildTranscriptPrompt", () => {
  it("labels passages with indices and times", () => {
    const prompt = buildTranscriptPrompt("Aurora", segments);
    expect(prompt).toContain("Episode title: Aurora");
    expect(prompt).toContain("[1] (00:20) Sensors on the ship.");
  });

  it("shortens very long transcripts evenly", () => {
    const long = Array.from({ length: 10 }, (_, index) => ({ startSec: index, endSec: index + 1, text: "x".repeat(1000) }));
    const prompt = buildTranscriptPrompt("Long", long, 2000);
    expect(prompt.length).toBeLessThan(3500);
    expect(prompt.match(/^\[\d+\]/gm)).toHaveLength(10);
  });
});

describe("mapWithConcurrency", () => {
  it("limits parallel calls and keeps order", async () => {
    let active = 0;
    let peak = 0;
    const result = await mapWithConcurrency([30, 10, 20, 0], 2, async (delay, index) => {
      active += 1;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, delay));
      active -= 1;
      return index;
    });
    expect(result).toEqual([0, 1, 2, 3]);
    expect(peak).toBe(2);
  });

  it("stops starting new work after a failure", async () => {
    const started: number[] = [];
    await expect(mapWithConcurrency([1, 2, 3, 4], 1, async (item) => {
      started.push(item);
      if (item === 2) throw new Error("boom");
      return item;
    })).rejects.toThrow("boom");
    expect(started).toEqual([1, 2]);
  });
});
