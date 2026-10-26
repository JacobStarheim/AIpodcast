import { describe, expect, it } from "vitest";
import {
  estimatePlayFrom,
  stemPrefix,
  fuseRankings,
  hasSufficientGrounding,
  sanitizeHistory,
  searchTerms,
  sortSegmentsByScoreDescending
} from "../src/retrieval.js";
import { segment } from "./fakes.js";

describe("hasSufficientGrounding", () => {
  it("sorts retrieval candidates by score", () => {
    const sorted = sortSegmentsByScoreDescending([
      {
        segmentId: "seg-low",
        kind: "segment",
        episodeId: "ep1",
        episodeTitle: "Episode",
        startSec: 10,
        endSec: 12,
        text: "low",
        score: 0.41
      },
      {
        segmentId: "seg-high",
        kind: "segment",
        episodeId: "ep1",
        episodeTitle: "Episode",
        startSec: 0,
        endSec: 3,
        text: "high",
        score: 0.85
      }
    ]);

    expect(sorted[0]?.segmentId).toBe("seg-high");
  });

  it("returns grounded=true when top score meets threshold", () => {
    const result = hasSufficientGrounding(
      [
        {
          segmentId: "seg1",
          kind: "segment",
          episodeId: "ep1",
          episodeTitle: "Episode",
          startSec: 1,
          endSec: 4,
          text: "content",
          score: 0.71
        }
      ],
      0.45
    );

    expect(result.grounded).toBe(true);
    expect(result.topScore).toBeCloseTo(0.71);
  });

  it("returns grounded=false when there are no segments", () => {
    const result = hasSufficientGrounding([], 0.45);
    expect(result.grounded).toBe(false);
    expect(result.topScore).toBe(0);
  });
});

describe("searchTerms", () => {
  it("keeps names and numbers and drops common English and Norwegian words", () => {
    expect(searchTerms(["How many sensors does the research ship Aurora carry?", "Hvor mange sensorer har Aurora i 2024?"]))
      .toEqual(["sensor", "resear", "ship", "aurora", "carry", "2024"]);
  });

  it("caps the number of terms", () => {
    expect(searchTerms(["alpha bravo charlie delta echo"], 3)).toEqual(["alpha", "bravo", "charli"]);
  });
});

describe("fuseRankings", () => {
  it("rewards passages found by several searches and keeps the best similarity", () => {
    const a = segment({ segmentId: "a", score: 0.5 });
    const b = segment({ segmentId: "b", score: 0.8 });
    const c = segment({ segmentId: "c", score: 0 });
    const fused = fuseRankings([[b, a], [a, b], [c, { ...a, score: 0 }]], 2);
    expect(fused.map((item) => item.segmentId)).toEqual(["a", "b"]);
    expect(fused[0]?.score).toBe(0.5);
  });
});

describe("sanitizeHistory", () => {
  it("keeps the last well-formed turns and trims them", () => {
    const turns = Array.from({ length: 8 }, (_, index) => ({ question: ` q${index} `, answer: "a".repeat(1200) }));
    const history = sanitizeHistory([...turns, { question: 5 }, null, "x", { question: "", answer: "" }]);
    expect(history).toHaveLength(6);
    expect(history[0]?.question).toBe("q2");
    expect(history[0]?.answer).toHaveLength(1000);
    expect(sanitizeHistory("nope")).toEqual([]);
  });
});

describe("stemPrefix", () => {
  it("shortens long words so inflected forms share a prefix", () => {
    expect(stemPrefix("driftsperioden")).toBe("driftsperio");
    expect("driftsperiode".startsWith(stemPrefix("driftsperioden"))).toBe(true);
    expect(stemPrefix("planlagte")).toBe("planla");
    expect(stemPrefix("aurora")).toBe("aurora");
    expect(stemPrefix("2024")).toBe("2024");
  });
});

describe("estimatePlayFrom", () => {
  const passage = { kind: "segment", startSec: 100, endSec: 120, text: "Intro words here. The answer starts now and goes on." };

  it("moves to the quote's position, a little early", () => {
    const at = estimatePlayFrom(passage, "The answer starts now");
    expect(at).toBeGreaterThan(100);
    expect(at).toBeLessThan(107);
  });

  it("falls back to the passage start", () => {
    expect(estimatePlayFrom(passage, "words that are not there")).toBe(100);
    expect(estimatePlayFrom(passage, "")).toBe(100);
    expect(estimatePlayFrom({ ...passage, kind: "chapter" }, "The answer starts now")).toBe(100);
  });
});
