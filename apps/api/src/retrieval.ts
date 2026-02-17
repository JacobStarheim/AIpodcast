import type { RetrievedSegment } from "./types.js";

export function sortSegmentsByScoreDescending(
  segments: RetrievedSegment[]
): RetrievedSegment[] {
  return [...segments].sort((a, b) => b.score - a.score);
}

export function hasSufficientGrounding(
  segments: RetrievedSegment[],
  minimumScore: number
): { grounded: boolean; topScore: number } {
  const topScore = sortSegmentsByScoreDescending(segments)[0]?.score ?? 0;
  return {
    grounded: segments.length > 0 && topScore >= minimumScore,
    topScore
  };
}
