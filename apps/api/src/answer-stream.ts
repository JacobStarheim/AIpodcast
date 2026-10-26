const ESCAPES: Record<string, string> = {
  n: "\n", t: "\t", r: "\r", b: "\b", f: "\f", "\"": "\"", "\\": "\\", "/": "/"
};

/**
 * Pulls the value of `"answerText"` out of JSON that arrives in fragments, so
 * the answer can be shown while the model is still writing the rest of the
 * object. Requires answerText to be the first property, which the schema
 * orders.
 */
export class AnswerTextExtractor {
  private buffer = "";
  private position = -1;
  private finished = false;

  /** Adds a fragment and returns any newly decoded answer text. */
  push(fragment: string): string {
    if (this.finished) return "";
    this.buffer += fragment;
    if (this.position < 0) {
      const start = /"answerText"\s*:\s*"/.exec(this.buffer);
      if (!start) return "";
      this.position = start.index + start[0].length;
    }
    let text = "";
    while (this.position < this.buffer.length) {
      const character = this.buffer[this.position]!;
      if (character === "\"") {
        this.finished = true;
        break;
      }
      if (character === "\\") {
        const next = this.buffer[this.position + 1];
        if (next === undefined) break;
        if (next === "u") {
          const hex = this.buffer.slice(this.position + 2, this.position + 6);
          if (hex.length < 4) break;
          text += String.fromCharCode(parseInt(hex, 16));
          this.position += 6;
          continue;
        }
        text += ESCAPES[next] ?? next;
        this.position += 2;
        continue;
      }
      text += character;
      this.position += 1;
    }
    return text;
  }
}

/**
 * Drops evidence markers such as " [3]" or " [0, 2]" (with the space before
 * them) from streamed text, matching what the final answer strips. Text that
 * could still become a marker is held back until it is clear.
 */
export class MarkerFilter {
  private pending = "";

  push(text: string): string {
    let output = "";
    for (const character of text) {
      this.pending += character;
      if (/^\s*\[\d+(?:\s*,\s*\d+)*\]$/.test(this.pending)) {
        this.pending = "";
      } else if (!/^\s*(?:\[[\d,\s]*)?$/.test(this.pending)) {
        // Not a marker after all: release everything but trailing whitespace.
        const whitespace = /\s*$/.exec(this.pending)?.[0] ?? "";
        output += this.pending.slice(0, this.pending.length - whitespace.length);
        this.pending = whitespace;
      }
    }
    return output;
  }

  flush(): string {
    const rest = this.pending;
    this.pending = "";
    return rest;
  }
}
