import { describe, expect, it } from "vitest";
import { AnswerTextExtractor, MarkerFilter } from "../src/answer-stream.js";
import { detectLanguage, guessLanguage, languageName, refusalText } from "../src/localize.js";

describe("language of a question", () => {
  it.each([
    ["How many sensors does the ship carry?", "en"],
    ["Hvor mange sensorer har skipet?", "nb"],
    ["Kva seier dei om skipet?", "nn"],
    ["Vad säger de om skeppet?", "sv"],
    ["Hvad siger de om skibet?", "da"],
    ["Blåbær", "nb"]
  ])("%s → %s", (question, language) => {
    expect(guessLanguage(question)).toBe(language);
  });

  it("reports no language when none of the known words occur", () => {
    expect(detectLanguage("Zeigt Aurora Sensoren?")).toBeNull();
    expect(guessLanguage("Zeigt Aurora Sensoren?")).toBe("en");
  });

  it("names languages for the answer model", () => {
    expect(languageName("nb")).toBe("Norwegian Bokmål (nb)");
    expect(languageName("en")).toBe("English (en)");
    expect(languageName("not a code")).toBe("not a code");
  });

  it("refuses in that language, falling back to English", () => {
    expect(refusalText("nb-NO")).toContain("Jeg finner ikke");
    expect(refusalText("no")).toContain("Jeg finner ikke");
    expect(refusalText("fr")).toContain("I do not have enough");
    expect(refusalText(null)).toContain("I do not have enough");
  });
});

describe("AnswerTextExtractor", () => {
  it("decodes the answer text from JSON split anywhere", () => {
    const json = JSON.stringify({ answerText: "Line one\n“Quoted” — \\ done", citations: [{ index: 0, quote: "x" }] });
    for (const size of [1, 2, 3, 7]) {
      const extractor = new AnswerTextExtractor();
      let text = "";
      for (let offset = 0; offset < json.length; offset += size) text += extractor.push(json.slice(offset, offset + size));
      expect(text).toBe("Line one\n“Quoted” — \\ done");
    }
  });

  it("decodes unicode escapes", () => {
    const extractor = new AnswerTextExtractor();
    expect(extractor.push('{"answerText":"Troms\\u00f8')).toBe("Tromsø");
    expect(extractor.push('"}')).toBe("");
  });
});

describe("MarkerFilter", () => {
  it("removes chunk markers split across pieces and keeps other brackets", () => {
    const filter = new MarkerFilter();
    const output = ["Five listeners [", "0", "]. A list [a] and [1, ", "2] end [3"].map((piece) => filter.push(piece)).join("");
    expect(output + filter.flush()).toBe("Five listeners. A list [a] and end [3");
  });
});

describe("TRUST_PROXY", () => {
  it("turns hop counts into numbers so Express does not read them as addresses", async () => {
    const { parseTrustProxy } = await import("../src/config.js");
    expect(parseTrustProxy(undefined)).toBe(false);
    expect(parseTrustProxy("1")).toBe(1);
    expect(parseTrustProxy("true")).toBe(true);
    expect(parseTrustProxy("uniquelocal")).toBe("uniquelocal");
  });
});
