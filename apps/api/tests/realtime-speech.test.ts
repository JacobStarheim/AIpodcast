import { afterEach, describe, expect, it, vi } from "vitest";
import type { RealtimeClientEvent, RealtimeServerEvent } from "openai/resources/realtime/realtime";
import {
  synthesizeRealtimeSpeech,
  type RealtimeSpeechTransport
} from "../src/realtime-speech.js";

class FakeTransport implements RealtimeSpeechTransport {
  sent: RealtimeClientEvent[] = [];
  closed = 0;
  handlers!: Parameters<RealtimeSpeechTransport["subscribe"]>[0];
  subscribe(handlers: Parameters<RealtimeSpeechTransport["subscribe"]>[0]) { this.handlers = handlers; }
  send(event: RealtimeClientEvent) { this.sent.push(event); }
  close() { this.closed++; this.handlers.onClose(); }
  emit(event: object) { this.handlers.onEvent(event as RealtimeServerEvent); }
  ready() {
    this.emit({ type: "session.created" });
    this.emit({ type: "session.updated" });
    this.emit({ type: "response.created", response: { id: "response_1" } });
  }
  audio(pcm = Buffer.from([1, 0, 2, 0])) {
    this.emit({
      type: "response.output_audio.delta", response_id: "response_1", delta: pcm.toString("base64")
    });
  }
  done(transcript = "Hei, verden!", status = "completed") {
    this.emit({
      type: "response.done",
      response: {
        id: "response_1", status,
        output: [{
          type: "message", role: "assistant",
          content: [{ type: "output_audio", transcript }]
        }]
      }
    });
  }
}

function setup(overrides: Partial<Parameters<typeof synthesizeRealtimeSpeech>[0]> = {}) {
  const socket = new FakeTransport();
  const promise = synthesizeRealtimeSpeech({
    apiKey: "test-key", model: "gpt-realtime-2.1-mini", text: "Hei, verden!", ...overrides
  }, () => socket);
  return { socket, promise };
}

afterEach(() => vi.useRealTimers());

describe("Realtime speech", () => {
  it("waits for session configuration and wraps streamed PCM in a playable mono WAV", async () => {
    const { socket, promise } = setup();
    expect(socket.sent).toEqual([]);
    socket.emit({ type: "session.created" });
    expect(socket.sent).toHaveLength(1);
    expect(socket.sent[0]).toMatchObject({
      type: "session.update",
      session: {
        output_modalities: ["audio"],
        audio: { input: { turn_detection: null }, output: { format: { type: "audio/pcm", rate: 24000 } } }
      }
    });
    socket.emit({ type: "session.updated" });
    socket.emit({ type: "session.updated" });
    expect(socket.sent).toHaveLength(2);
    expect(socket.sent[1]).toMatchObject({
      type: "response.create",
      response: {
        conversation: "none", tool_choice: "none",
        input: [{ type: "message", role: "user", content: [{ type: "input_text", text: "Hei, verden!" }] }]
      }
    });
    socket.emit({ type: "response.created", response: { id: "response_1" } });
    socket.audio(Buffer.from([1, 0]));
    socket.audio(Buffer.from([2, 0]));
    socket.done("HEI VERDEN.");
    const result = await promise;
    const wav = Buffer.from(result.audioBase64, "base64");
    expect(result.mimeType).toBe("audio/wav");
    expect(wav.subarray(0, 4).toString()).toBe("RIFF");
    expect(wav.subarray(8, 12).toString()).toBe("WAVE");
    expect(wav.readUInt32LE(4)).toBe(wav.length - 8);
    expect(wav.readUInt16LE(22)).toBe(1);
    expect(wav.readUInt32LE(24)).toBe(24000);
    expect(wav.readUInt16LE(34)).toBe(16);
    expect(wav.readUInt32LE(40)).toBe(4);
    expect(wav.subarray(44)).toEqual(Buffer.from([1, 0, 2, 0]));
    expect(socket.closed).toBe(1);
  });

  it.each(["Selvfølgelig! Hei, verden!", "Hei!", "Good morning!"])(
    "rejects changed, additional, missing, or translated speech: %s",
    async (transcript) => {
      const { socket, promise } = setup();
      socket.ready();
      socket.audio();
      socket.done(transcript);
      await expect(promise).rejects.toThrow("did not match");
      expect(socket.closed).toBe(1);
    }
  );

  it.each([
    ["The temperature is -3 degrees.", "The temperature is 3 degrees."],
    ["The temperature is −3 degrees.", "The temperature is 3 degrees."],
    ["The change is +3%.", "The change is 3%."],
    ["The change is 3%.", "The change is 3."],
    ["The error is ±3.", "The error is 3."]
  ])("rejects changed numeric signs or percentages in %s", async (text, transcript) => {
    const { socket, promise } = setup({ text });
    socket.ready();
    socket.audio();
    socket.done(transcript);
    await expect(promise).rejects.toThrow("did not match");
    expect(socket.closed).toBe(1);
  });

  it("continues accepting harmless word hyphens and sentence punctuation", async () => {
    const { socket, promise } = setup({ text: "Twenty-four sensors; the change is -3%." });
    socket.ready();
    socket.audio();
    socket.done("Twenty four sensors. The change is -3%!");
    await expect(promise).resolves.toMatchObject({ mimeType: "audio/wav" });
  });

  it("rejects missing transcripts even when another audio part matches the answer", async () => {
    const { socket, promise } = setup();
    socket.ready();
    socket.audio();
    socket.emit({
      type: "response.done",
      response: {
        id: "response_1", status: "completed",
        output: [{
          type: "message", role: "assistant",
          content: [
            { type: "output_audio", transcript: "Hei, verden!" },
            { type: "output_audio" }
          ]
        }]
      }
    });
    await expect(promise).rejects.toThrow("complete transcript");
    expect(socket.closed).toBe(1);
  });

  it.each(["cancelled", "incomplete", "failed"])("rejects %s responses even with audio", async (status) => {
    const { socket, promise } = setup();
    socket.ready();
    socket.audio();
    socket.done("Hei, verden!", status);
    await expect(promise).rejects.toThrow("did not complete");
    expect(socket.closed).toBe(1);
  });

  it("rejects empty audio and odd PCM byte counts", async () => {
    for (const pcm of [Buffer.alloc(0), Buffer.from([1])]) {
      const { socket, promise } = setup();
      socket.ready();
      socket.audio(pcm);
      socket.done();
      await expect(promise).rejects.toThrow("invalid audio");
      expect(socket.closed).toBe(1);
    }
  });

  it("rejects malformed base64 and oversized audio", async () => {
    const first = setup();
    first.socket.ready();
    first.socket.emit({ type: "response.output_audio.delta", response_id: "response_1", delta: "not base64!" });
    await expect(first.promise).rejects.toThrow("invalid audio");
    const second = setup({ maxAudioBytes: 2 });
    second.socket.ready();
    second.socket.audio();
    await expect(second.promise).rejects.toThrow("size limit");
    expect(first.socket.closed).toBe(1);
    expect(second.socket.closed).toBe(1);
  });

  it("closes a stalled request at its deadline", async () => {
    vi.useFakeTimers();
    const { socket, promise } = setup({ timeoutMs: 100 });
    const assertion = expect(promise).rejects.toThrow("timed out");
    await vi.advanceTimersByTimeAsync(100);
    await assertion;
    expect(socket.closed).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("propagates connection errors and rejects early closure without waiting for the deadline", async () => {
    const first = setup();
    first.socket.handlers.onError(new Error("Connection failed"));
    await expect(first.promise).rejects.toThrow("Connection failed");
    const second = setup();
    second.socket.handlers.onClose();
    await expect(second.promise).rejects.toThrow("closed before completion");
    expect(first.socket.closed).toBe(1);
    expect(second.socket.closed).toBe(1);
  });

  it("rejects invalid input before opening a paid session", async () => {
    const factory = vi.fn();
    await expect(synthesizeRealtimeSpeech({
      apiKey: "test-key", model: "gpt-realtime-2.1-mini", text: "  "
    }, factory)).rejects.toThrow("Speech text");
    expect(factory).not.toHaveBeenCalled();
  });
});
