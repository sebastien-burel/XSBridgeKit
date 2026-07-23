// fetch_url — fetch the text at an HTTP(S) URL. HTML is stripped of tags +
// scripts/styles down to flat text (crude, good enough for an LLM to summarise).
import { httpGet } from "./http.js";

function stripHTML(html) {
  let s = html;
  s = s.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, " ")
       .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, " ");
  s = s.replace(/<[^>]+>/g, " ");
  const entities = {
    "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'", "&nbsp;": " ",
  };
  s = s.replace(/&amp;|&lt;|&gt;|&quot;|&#39;|&nbsp;/g, (m) => entities[m]);
  s = s.replace(/\s+/g, " ");
  return s.trim();
}

export default {
  name: "fetch_url",
  description:
    "Fetches the textual content at a public HTTP or HTTPS URL and returns the "
    + "body. For HTML pages, tags and inline scripts/styles are stripped, leaving "
    + "the readable text. Use when you need to read the content of a web page the "
    + "user mentions. The result is capped at max_chars characters (default 10000).",
  input_schema: {
    type: "object",
    properties: {
      url: { type: "string", description: "The HTTP or HTTPS URL to fetch." },
      max_chars: {
        type: "integer",
        description: "Maximum number of characters to return (default 10000).",
        minimum: 100, maximum: 100000,
      },
    },
    required: ["url"],
    additionalProperties: false,
  },
  async run(args) {
    const url = String((args && args.url) || "");
    if (!/^https?:\/\//i.test(url)) throw new Error("url must be http(s)");

    const res = await httpGet(url, {
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "User-Agent": "TyKaoz/0.1 (macOS; +https://tykaoz.bzh)",
    });
    if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status);

    const text = res.contentType.includes("html") ? stripHTML(res.text) : res.text;
    const limit = (args && args.max_chars) || 10000;
    return text.length > limit ? text.slice(0, limit) + "\n[truncated]" : text;
  },
};
