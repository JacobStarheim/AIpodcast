import { describe, expect, it } from "vitest";
import { buildContextTexts, chunkTranscriptSegments } from "../src/chunking.js";

describe("chunkTranscriptSegments", () => {
  it("preserves timestamp continuity while chunking", () => {
    const chunks = chunkTranscriptSegments(
      [
        { start: 0, end: 5, text: "Hello and welcome to the show." },
        { start: 5, end: 12, text: "Today we discuss podcast indexing." },
        { start: 12, end: 20, text: "Citations improve trust for listeners." },
        { start: 20, end: 29, text: "Latency and grounding matter." }
      ],
      { maxChars: 65, maxDurationSec: 15 }
    );

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks[0]?.startSec).toBe(0);

    for (let i = 0; i < chunks.length; i += 1) {
      const chunk = chunks[i];
      expect(chunk.endSec).toBeGreaterThanOrEqual(chunk.startSec);

      if (i > 0) {
        expect(chunk.startSec).toBeGreaterThanOrEqual(chunks[i - 1].endSec);
      }
    }
  });
});

describe("buildContextTexts", () => {
  it("adds the neighbouring passages, cut at word boundaries", () => {
    const texts = buildContextTexts(
      [{ text: "alpha beta gamma delta" }, { text: "middle passage" }, { text: "omega psi chi phi" }],
      11
    );
    expect(texts).toEqual([
      "alpha beta gamma delta\nmiddle",
      "gamma delta\nmiddle passage\nomega psi",
      "passage\nomega psi chi phi"
    ]);
  });
});
