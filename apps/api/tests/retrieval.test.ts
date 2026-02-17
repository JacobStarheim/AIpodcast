import { describe, expect, it } from "vitest";
import { hasSufficientGrounding, sortSegmentsByScoreDescending } from "../src/retrieval.js";

describe("hasSufficientGrounding", () => {
  it("sorts retrieval candidates by score", () => {
    const sorted = sortSegmentsByScoreDescending([
      {
        segmentId: "seg-low",
        episodeId: "ep1",
        episodeTitle: "Episode",
        startSec: 10,
        endSec: 12,
        text: "low",
        score: 0.41
      },
      {
        segmentId: "seg-high",
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
