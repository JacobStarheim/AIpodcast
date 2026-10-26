import { describe, expect, it } from "vitest";
import { answerQuestion } from "../src/qa-service.js";
import { EPISODE_ID, FakeAIClient, FakeRepository, segment } from "./fakes.js";

function setup() {
  const repository = new FakeRepository();
  const aiClient = new FakeAIClient();
  const errors: unknown[] = [];
  const ask = (input: Partial<Parameters<typeof answerQuestion>[1]> & { questionText: string }) =>
    answerQuestion(
      { repository, aiClient, minGroundingScore: 0.45, logError: (_message, error) => errors.push(error) },
      { history: [], topK: 6, ...input }
    );
  return { repository, aiClient, errors, ask };
}

describe("answerQuestion", () => {
  it("searches with the question and the planned, translated queries", async () => {
    const { repository, aiClient, ask } = setup();
    aiClient.defaultScore = 0.5;
    aiClient.plan = { queries: ["how many sensors does Aurora carry"], overview: false };
    const response = await ask({ questionText: "Hvor mange sensorer har Aurora?", episodeId: EPISODE_ID });

    expect(response.grounded).toBe(true);
    expect(aiClient.planCalls[0]).toMatchObject({ transcriptLanguages: ["en"] });
    expect(aiClient.embedded).toEqual([["Hvor mange sensorer har Aurora?"], ["how many sensors does Aurora carry"]]);
    expect(repository.vectorQueries).toHaveLength(2);
    expect(repository.vectorQueries.every((query) => query.episodeId === EPISODE_ID)).toBe(true);
    expect(repository.textQueries[0]?.terms).toEqual(["sensorer", "aurora", "sensors", "carry"]);
  });

  it("falls back to the question as asked when planning fails", async () => {
    const { aiClient, errors, ask } = setup();
    aiClient.defaultScore = 0.5;
    aiClient.planSearch = async () => {
      throw new Error("planner down");
    };
    const response = await ask({ questionText: "What about the architecture?", episodeId: EPISODE_ID });
    expect(response.grounded).toBe(true);
    expect(aiClient.embedded).toEqual([["What about the architecture?"]]);
    expect(errors).toHaveLength(1);
  });

  it("answers a confident first question without waiting for the plan", async () => {
    const { aiClient, repository, ask } = setup();
    let planSignal: AbortSignal | undefined;
    aiClient.planSearch = (input) => {
      planSignal = input.signal;
      return new Promise((_resolve, reject) => {
        input.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      });
    };
    const response = await ask({ questionText: "What did the host say?", episodeId: EPISODE_ID });
    expect(response.grounded).toBe(true);
    expect(planSignal?.aborted).toBe(true);
    expect(repository.vectorQueries).toHaveLength(1);
  });

  it("waits for the plan when the first match is only moderate", async () => {
    const { aiClient, ask } = setup();
    aiClient.defaultScore = 0.55;
    let planned = false;
    aiClient.planSearch = async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      planned = true;
      return { queries: ["translated query"], overview: false };
    };
    await ask({ questionText: "Moderate match", episodeId: EPISODE_ID });
    expect(planned).toBe(true);
    expect(aiClient.embedded).toEqual([["Moderate match"], ["translated query"]]);
  });

  it("passes the conversation to planning and answering", async () => {
    const { aiClient, ask } = setup();
    const history = [{ question: "Who is the guest?", answer: "Ada." }];
    await ask({ questionText: "What did she build?", episodeId: EPISODE_ID, history });
    expect(aiClient.planCalls[0]?.history).toEqual(history);
    expect(aiClient.answerCalls[0]?.history).toEqual(history);
    expect(aiClient.answerCalls[0]?.episodeSummary).toBe("An episode about prototypes.");
  });

  it("puts what was just heard first and lets it ground the answer", async () => {
    const { repository, aiClient, ask } = setup();
    repository.vectorResults = [];
    const response = await ask({ questionText: "unsupported: what did they just mean?", episodeId: EPISODE_ID, positionSec: 615 });

    expect(response.grounded).toBe(true);
    const evidence = aiClient.answerCalls[0]!.evidence;
    expect(evidence[0]).toMatchObject({ segmentId: "seg_recent", recentlyHeard: true });
    expect(response.citations[0]).toEqual(expect.objectContaining({ segmentId: "seg_recent", kind: "segment" }));
    expect(response.citations[0]).not.toHaveProperty("recentlyHeard");
  });

  it("answers overview questions from chapters even when no passage is similar", async () => {
    const { aiClient, ask } = setup();
    aiClient.plan = { queries: ["unsupported overview"], overview: true };
    aiClient.answerGrounded = async (input) => {
      aiClient.answerCalls.push(input);
      return { answerText: "It covers the architecture.", citationIndices: [input.evidence.length - 1] };
    };
    const response = await ask({ questionText: "unsupported: what is this episode about?", episodeId: EPISODE_ID });

    expect(response.grounded).toBe(true);
    expect(response.citations).toEqual([expect.objectContaining({
      segmentId: "chapter:c1", kind: "chapter", startSec: 0, text: "Architecture: How it is built."
    })]);
  });

  it("still refuses a specific question with no similar passage", async () => {
    const { aiClient, ask } = setup();
    const response = await ask({ questionText: "unsupported: captain's name?", episodeId: EPISODE_ID });
    expect(response).toMatchObject({ grounded: false, refusalReason: "insufficient_retrieval_confidence" });
    expect(aiClient.answerCalls).toHaveLength(0);
  });

  it("accepts a strong keyword match even when vectors are weak", async () => {
    const { repository, ask } = setup();
    repository.textResults = [segment({ segmentId: "seg_kw", text: "Aurora carries 24 sensors", score: 0 })];
    const response = await ask({ questionText: "unsupported: Aurora sensors count" });
    expect(response.grounded).toBe(true);
  });

  it("searches the whole library and its chapters without an episode", async () => {
    const { repository, aiClient, ask } = setup();
    repository.readyLanguages = ["en", "nb"];
    repository.chapterResults = [segment({ segmentId: "chapter:x", kind: "chapter", episodeId: "other", score: 0.7 })];
    const response = await ask({ questionText: "Which episode covers architecture?" });

    expect(response.grounded).toBe(true);
    expect(aiClient.planCalls[0]?.transcriptLanguages).toEqual(["en", "nb"]);
    expect(repository.vectorQueries[0]?.episodeId).toBeUndefined();
    expect(aiClient.answerCalls[0]?.evidence.map((item) => item.segmentId)).toEqual(["seg_1", "chapter:x"]);
    expect(aiClient.answerCalls[0]?.episodeSummary).toBeNull();
  });

  it("logs every question with its outcome", async () => {
    const { repository, ask } = setup();
    await ask({ questionText: "What did the host say?", episodeId: EPISODE_ID });
    await ask({ questionText: "unsupported", episodeId: EPISODE_ID });
    expect(repository.qaEvents).toEqual([
      expect.objectContaining({ episodeId: EPISODE_ID, grounded: true }),
      expect.objectContaining({ episodeId: EPISODE_ID, grounded: false })
    ]);
  });

  it("gives the model the passages next to each hit", async () => {
    const { repository, aiClient, ask } = setup();
    repository.neighbours = [segment({ segmentId: "seg_next", startSec: 152, endSec: 170, text: "The answer is here." })];
    await ask({ questionText: "What did the host say?", episodeId: EPISODE_ID });
    expect(aiClient.answerCalls[0]?.evidence.map((item) => item.segmentId)).toEqual(["seg_1", "seg_next", "chapter:c1"]);
  });
});
