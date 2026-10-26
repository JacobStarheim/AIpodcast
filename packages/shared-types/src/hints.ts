const ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", rsquo: "’", lsquo: "‘",
  rdquo: "”", ldquo: "“", mdash: "—", ndash: "–", hellip: "…"
};

/** Plain text from an RSS description that may contain HTML. */
export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (match, entity: string) => {
      if (entity.startsWith("#")) {
        const code = entity[1]?.toLowerCase() === "x" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
        return Number.isFinite(code) ? String.fromCodePoint(code) : match;
      }
      return ENTITIES[entity.toLowerCase()] ?? match;
    })
    .replace(/\s+/g, " ")
    .trim();
}

const NAME_WORD = "\\p{Lu}[\\p{L}'’-]*";
const CONNECTOR = "(?:\\s(?:de|da|del|der|van|von|la|le|af|av|bin|al))?";
const NAME_PATTERN = new RegExp(`${NAME_WORD}(?:${CONNECTOR}\\s${NAME_WORD}){1,3}`, "gu");
// Capitalised phrases that are rarely the name of a person or show.
const SKIP_START = /^(The|This|That|These|Those|We|Our|In|On|At|For|With|And|But|Or|If|When|What|Why|How|Who|Den|Det|De|Vi|Når|Hva|Hvorfor|Hvordan)\s/u;

/** Lines of an HTML description, split at block tags and sentence ends. */
function lines(html: string): string[] {
  return html
    .split(/<\/?(?:p|li|ul|ol|div|h\d|br)\b[^>]*>|(?<=[.!?])\s+/i)
    .map(htmlToText)
    .filter(Boolean);
}

/** Headlines in title case ("Partner Has New Start-Up") are not names. */
function isTitleCase(line: string): boolean {
  const words = line.split(/\s+/).filter((word) => /\p{L}/u.test(word));
  if (words.length < 5) return false;
  const capitalised = words.filter((word) => /^\p{Lu}/u.test(word)).length;
  return capitalised / words.length > 0.8;
}

/**
 * Names and titles worth giving a transcription model as spelling hints:
 * runs of two to four capitalised words ("Erin Griffith", "Bad Blood"),
 * most frequent first. Headlines and sentence starts like "This week" are
 * skipped.
 */
export function extractNameHints(text: string, max = 25): string[] {
  const counts = new Map<string, number>();
  for (const line of lines(text)) {
    if (isTitleCase(line)) continue;
    for (const match of line.matchAll(NAME_PATTERN)) {
      const phrase = match[0].replace(/[’']+$/u, "");
      if (SKIP_START.test(phrase) || phrase.length > 60) continue;
      counts.set(phrase, (counts.get(phrase) ?? 0) + 1);
    }
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, max)
    .map(([phrase]) => phrase);
}

/**
 * Prompt for the transcription model: show and episode titles plus names
 * from the description, kept short because the model only uses the start.
 */
export function transcriptionPrompt(parts: { show?: string; title?: string; text?: string }, maxChars = 600): string {
  const known = `${parts.show ?? ""} ${parts.title ?? ""}`;
  const names = extractNameHints(parts.text ?? "").filter((name) => !known.includes(name));
  const prompt = [parts.show, parts.title, names.length ? `${names.join(", ")}.` : ""]
    .map((part) => part?.trim())
    .filter(Boolean)
    .join(". ");
  return prompt.length > maxChars ? prompt.slice(0, prompt.lastIndexOf(",", maxChars) + 1 || maxChars) : prompt;
}
