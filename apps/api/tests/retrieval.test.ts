import { describe, expect, it } from "vitest";
import {
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
      .toEqual(["sensors", "research", "ship", "aurora", "carry", "sensorer", "2024"]);
  });

  it("caps the number of terms", () => {
    expect(searchTerms(["alpha bravo charlie delta echo"], 3)).toEqual(["alpha", "bravo", "charlie"]);
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
