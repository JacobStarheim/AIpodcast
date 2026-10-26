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

function tail(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  const cut = text.slice(-maxChars);
  if (text[text.length - maxChars - 1] === " ") return cut;
  const space = cut.indexOf(" ");
  return space >= 0 ? cut.slice(space + 1) : cut;
}

function head(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  const cut = text.slice(0, maxChars);
  if (text[maxChars] === " ") return cut;
  const space = cut.lastIndexOf(" ");
  return space >= 0 ? cut.slice(0, space) : cut;
}

/**
 * The text embedded for each chunk: the chunk plus the end of the previous one
 * and the start of the next. A topic that spans a cut is then still found, while
 * citations keep the chunk's own times and text.
 */
export function buildContextTexts(chunks: { text: string }[], neighbourChars = 300): string[] {
  return chunks.map((chunk, index) => {
    const previous = chunks[index - 1];
    const next = chunks[index + 1];
    return [
      previous ? tail(previous.text, neighbourChars) : "",
      chunk.text,
      next ? head(next.text, neighbourChars) : ""
    ].filter(Boolean).join("\n");
  });
}
