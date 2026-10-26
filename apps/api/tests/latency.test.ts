import request from "supertest";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { APP_KEY, AUTH, FakeAIClient, FakeRepository } from "./fakes.js";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

class LatencyAiClient extends FakeAIClient {
  override async planSearch(input: Parameters<FakeAIClient["planSearch"]>[0]) {
    await wait(60);
    return super.planSearch(input);
  }

  override async embedTexts(texts: string[]) {
    await wait(40);
    return super.embedTexts(texts);
  }

  override async answerGrounded(input: Parameters<FakeAIClient["answerGrounded"]>[0]) {
    await wait(70);
    return super.answerGrounded(input);
  }

  override async synthesizeSpeech() {
    await wait(50);
    return super.synthesizeSpeech();
  }
}

describe("Latency target", () => {
  it("keeps mocked QA+TTS path under 4 seconds", async () => {
    const app = createApp({
      repository: new FakeRepository(),
      aiClient: new LatencyAiClient(),
      adminKey: "dev-admin",
      appApiKey: APP_KEY,
      minGroundingScore: 0.45
    });

    const start = Date.now();
    const qa = await request(app).post("/v1/qa/answer").set(AUTH).send({
      questionText: "latency test"
    });
    expect(qa.status).toBe(200);
    expect(qa.body.grounded).toBe(true);

    const tts = await request(app).post("/v1/voice/synthesize").set(AUTH).send({ text: qa.body.answerText });
    expect(tts.status).toBe(200);

    const elapsed = Date.now() - start;
    expect(elapsed).toBeLessThan(4000);
  });
});
