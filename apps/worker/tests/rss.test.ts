import { describe, expect, it } from "vitest";
import { parseFeed, parseRss } from "../src/rss.js";

const sampleRss = `
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Demo Podcast</title>
    <language>nb-no</language>
    <itunes:image href="https://example.com/show.jpg" />
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
      <itunes:image href="https://example.com/e2.jpg" />
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

describe("parseFeed", () => {
  it("reads the show title, language and artwork", () => {
    const feed = parseFeed(sampleRss);
    expect(feed).toMatchObject({
      title: "Demo Podcast",
      language: "nb-no",
      imageUrl: "https://example.com/show.jpg"
    });
    expect(feed.episodes[0]?.imageUrl).toBe("https://example.com/e2.jpg");
    expect(feed.episodes[1]?.imageUrl).toBeNull();
  });

  it("ignores an invalid language and non-HTTP artwork", () => {
    const feed = parseFeed(`<rss><channel><title>X</title><language>Norwegian Bokmal</language>
      <image><url>javascript:alert(1)</url></image></channel></rss>`);
    expect(feed).toMatchObject({ language: null, imageUrl: null, episodes: [] });
  });
});
