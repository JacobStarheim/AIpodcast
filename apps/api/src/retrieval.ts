import type { QATurn } from "@podcast/shared-types";
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

// Common English and Norwegian words that would match almost every passage.
const STOPWORDS = new Set(
  ("the and for are was were has have had did does what who whom which when where why how " +
   "that this these those with from into about they them their there then than you your " +
   "can could would should will just also its it's not but our out all any say said tell " +
   "many much some more most very does doing done been being episode podcast " +
   "og det som er var har hva hvem hvor hvordan hvorfor når med for til fra den dette disse " +
   "de deres han hun jeg vi dere seg sin sitt sine ikke men også bare kan kunne skal vil " +
   "ville noe noen mange mye om på av ett eller enn så sa sier episoden podkasten")
    .split(" ")
);

/**
 * Crude stem for keyword search: long words lose their last three letters so
 * that inflected forms match ("driftsperioden" → "driftsperio" matches
 * "driftsperiode", "planlagte" → "planla" matches "planlagt"). Used as a
 * prefix; never shorter than six letters.
 */
export function stemPrefix(term: string): string {
  if (/^\d+$/.test(term) || term.length <= 6) return term;
  return term.slice(0, Math.max(6, term.length - 3));
}

/**
 * Distinctive words for keyword search: names, numbers and rarer terms, as
 * stem prefixes (see stemPrefix).
 */
export function searchTerms(texts: string[], maxTerms = 16): string[] {
  const terms = new Set<string>();
  for (const text of texts) {
    for (const match of text.toLocaleLowerCase().matchAll(/[\p{L}\p{N}]+/gu)) {
      const term = match[0];
      if ((term.length >= 3 || /^\d+$/.test(term)) && !STOPWORDS.has(term)) terms.add(stemPrefix(term));
      if (terms.size >= maxTerms) return [...terms];
    }
  }
  return [...terms];
}

/**
 * Reciprocal rank fusion over several ranked lists (vector and keyword
 * searches for each query). Keeps the best vector similarity as `score`.
 */
export function fuseRankings(lists: RetrievedSegment[][], limit: number, k = 60): RetrievedSegment[] {
  const fused = new Map<string, { segment: RetrievedSegment; rank: number }>();
  for (const list of lists) {
    list.forEach((segment, position) => {
      const entry = fused.get(segment.segmentId);
      const contribution = 1 / (k + position + 1);
      if (entry) {
        entry.rank += contribution;
        if (segment.score > entry.segment.score) entry.segment = { ...entry.segment, score: segment.score };
      } else {
        fused.set(segment.segmentId, { segment, rank: contribution });
      }
    });
  }
  return [...fused.values()]
    .sort((a, b) => b.rank - a.rank)
    .slice(0, limit)
    .map((entry) => entry.segment);
}

/** Accepts only well-formed turns and bounds what reaches the models. */
export function sanitizeHistory(value: unknown, maxTurns = 6, maxChars = 1000): QATurn[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((turn): turn is QATurn =>
      Boolean(turn) && typeof turn === "object" &&
      typeof (turn as QATurn).question === "string" && typeof (turn as QATurn).answer === "string")
    .map((turn) => ({
      question: turn.question.trim().slice(0, maxChars),
      answer: turn.answer.trim().slice(0, maxChars)
    }))
    .filter((turn) => turn.question.length > 0)
    .slice(-maxTurns);
}

function normalizeForMatch(text: string): string {
  return text.toLocaleLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim();
}

/**
 * Where to start playing for a quote from a passage. Passages last 10–30
 * seconds without word timings, so the start is estimated from the quote's
 * position in the text and moved a little earlier.
 */
export function estimatePlayFrom(
  passage: { kind: string; startSec: number; endSec: number; text: string },
  quote: string,
  leadInSec = 1.5
): number {
  if (passage.kind !== "segment") return passage.startSec;
  const text = normalizeForMatch(passage.text);
  const words = normalizeForMatch(quote).split(" ").filter(Boolean);
  let offset = -1;
  for (let length = Math.min(6, words.length); length >= 2 && offset < 0; length -= 1) {
    offset = text.indexOf(words.slice(0, length).join(" "));
  }
  if (offset <= 0) return passage.startSec;
  const estimate = passage.startSec + (offset / text.length) * (passage.endSec - passage.startSec) - leadInSec;
  return Math.round(Math.min(passage.endSec, Math.max(passage.startSec, estimate)) * 10) / 10;
}
