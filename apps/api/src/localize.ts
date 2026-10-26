const REFUSALS: Record<string, string> = {
  en: "I do not have enough transcript evidence to answer that confidently.",
  nb: "Jeg finner ikke nok i transkripsjonen til å svare sikkert på det.",
  nn: "Eg finn ikkje nok i transkripsjonen til å svare sikkert på det.",
  sv: "Jag hittar inte tillräckligt i transkriptionen för att svara säkert på det.",
  da: "Jeg kan ikke finde nok i transskriptionen til at svare sikkert på det."
};

// Frequent words that are distinctive for each language.
const MARKERS: Record<string, string[]> = {
  en: ["the", "what", "did", "does", "how", "who", "why", "is", "are", "about", "they", "say", "of", "and"],
  nb: ["hva", "hvem", "hvor", "hvordan", "hvorfor", "ikke", "jeg", "det", "er", "og", "sa", "på", "har", "kan", "når", "hun", "han", "episoden"],
  nn: ["kva", "kven", "kor", "korleis", "kvifor", "ikkje", "eg", "dei", "ho"],
  sv: ["vad", "vem", "hur", "varför", "inte", "jag", "och", "är", "säger", "sade"],
  da: ["hvad", "hvem", "hvordan", "hvorfor", "ikke", "jeg", "og", "er", "siger", "sagde"]
};

/**
 * The language of a short question, from frequent words, or null when none of
 * the known languages' words occur. Used only when the search planner did not
 * report one.
 */
export function detectLanguage(text: string): string | null {
  const words = text.toLocaleLowerCase().match(/[\p{L}]+/gu) ?? [];
  let best: string | null = null;
  let bestScore = 0;
  for (const [language, markers] of Object.entries(MARKERS)) {
    const score = words.filter((word) => markers.includes(word)).length;
    if (score > bestScore) {
      best = language;
      bestScore = score;
    }
  }
  if (/[æøå]/i.test(text) && (best === "en" || best === null)) return "nb";
  return best;
}

/** Like detectLanguage, falling back to English. */
export function guessLanguage(text: string): string {
  return detectLanguage(text) ?? "en";
}

/** "Norwegian Bokmål (nb)" for a BCP 47 code, or the code alone if unknown. */
export function languageName(code: string): string {
  try {
    const name = new Intl.DisplayNames(["en"], { type: "language" }).of(code);
    return name && name !== code ? `${name} (${code})` : code;
  } catch {
    return code;
  }
}

/** The refusal in the question's language; Norwegian variants fall back to Bokmål. */
export function refusalText(language: string | null | undefined): string {
  const code = (language ?? "en").toLowerCase().split("-")[0] ?? "en";
  return REFUSALS[code === "no" ? "nb" : code] ?? REFUSALS.en!;
}
