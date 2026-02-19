export interface RawTranscriptSegment {
  start: number;
  end: number;
  text: string;
  speaker?: string;
}

export interface ChunkedTranscriptSegment {
  startSec: number;
  endSec: number;
  text: string;
  speaker: string | null;
}

export function chunkTranscriptSegments(
  segments: RawTranscriptSegment[],
  options: { maxChars?: number; maxDurationSec?: number } = {}
): ChunkedTranscriptSegment[] {
  const maxChars = options.maxChars ?? 900;
  const maxDurationSec = options.maxDurationSec ?? 120;

  const ordered = [...segments]
    .filter((segment) => segment.text.trim().length > 0)
    .sort((a, b) => a.start - b.start);

  if (ordered.length === 0) {
    return [];
  }

  const chunks: ChunkedTranscriptSegment[] = [];
  let current: ChunkedTranscriptSegment | null = null;

  for (const segment of ordered) {
    const normalizedText = segment.text.trim().replace(/\s+/g, " ");

    if (!current) {
      current = {
        startSec: segment.start,
        endSec: segment.end,
        text: normalizedText,
        speaker: segment.speaker?.trim() || null
      };
      continue;
    }

    const nextText = `${current.text} ${normalizedText}`.trim();
    const nextDuration = segment.end - current.startSec;
    const wouldOverflow = nextText.length > maxChars || nextDuration > maxDurationSec;

    if (wouldOverflow) {
      chunks.push(current);
      current = {
        startSec: segment.start,
        endSec: segment.end,
        text: normalizedText,
        speaker: segment.speaker?.trim() || null
      };
      continue;
    }

    current.text = nextText;
    current.endSec = segment.end;

    if (!current.speaker && segment.speaker) {
      current.speaker = segment.speaker.trim() || null;
    }
  }

  if (current) {
    chunks.push(current);
  }

  return chunks;
}
