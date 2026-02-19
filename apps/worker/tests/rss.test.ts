import { describe, expect, it } from "vitest";
import { parseRss } from "../src/rss.js";

const sampleRss = `
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Demo Podcast</title>
    <item>
      <guid>episode-1</guid>
      <title>Episode One</title>
      <description>First episode</description>
      <pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate>
      <enclosure url="https://example.com/e1.mp3" type="audio/mpeg" />
      <itunes:duration>00:10:05</itunes:duration>
    </item>
    <item>
      <guid>episode-1</guid>
      <title>Episode One Duplicate</title>
      <description>Duplicate should be deduped</description>
      <pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate>
      <enclosure url="https://example.com/e1.mp3" type="audio/mpeg" />
    </item>
    <item>
      <guid>episode-2</guid>
      <title>Episode Two</title>
      <description>Second episode</description>
      <pubDate>Tue, 02 Jan 2024 10:00:00 GMT</pubDate>
      <enclosure url="https://example.com/e2.mp3" type="audio/mpeg" />
      <itunes:duration>630</itunes:duration>
    </item>
  </channel>
</rss>
`;

describe("parseRss", () => {
  it("parses items and dedupes by GUID", () => {
    const episodes = parseRss(sampleRss);

    expect(episodes).toHaveLength(2);
    expect(episodes[0]?.guid).toBe("episode-2");
    expect(episodes[1]?.guid).toBe("episode-1");
    expect(episodes[1]?.durationSec).toBe(605);
  });
});
