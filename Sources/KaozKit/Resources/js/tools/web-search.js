// web_search — Brave Search API. The subscription token is passed in via
// globalThis.__toolConfig.braveApiKey (set by the loader).
import { httpGet } from "./http.js";

export default {
  name: "web_search",
  description:
    "Searches the web with Brave and returns the top results as title, URL and "
    + "snippet. Use for current events or facts that may be outside your "
    + "knowledge. Returns up to `count` results (default 5).",
  input_schema: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query." },
      count: {
        type: "integer",
        description: "Number of results to return (1-20, default 5).",
        minimum: 1, maximum: 20,
      },
    },
    required: ["query"],
    additionalProperties: false,
  },
  async run(args) {
    const cfg = globalThis.__toolConfig || {};
    const key = (cfg.braveApiKey || "").trim();
    if (!key) throw new Error("clé API Brave manquante (réglages → Outils)");
    const query = String((args && args.query) || "").trim();
    if (!query) throw new Error("query ne peut pas être vide");
    const count = Math.min(Math.max((args && args.count) || 5, 1), 20);

    const base = (cfg.braveBaseURL || "https://api.search.brave.com").replace(/\/+$/, "");
    const url = base + "/res/v1/web/search?q="
      + encodeURIComponent(query) + "&count=" + count;
    const res = await httpGet(url, {
      "Accept": "application/json",
      "X-Subscription-Token": key,
    });
    if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status);

    let data; try { data = JSON.parse(res.text); } catch (e) { data = {}; }
    const results = (data.web && data.web.results) || [];
    if (!results.length) return "Aucun résultat.";
    return results.slice(0, count).map((r, i) =>
      (i + 1) + ". " + (r.title || "(sans titre)") + "\n" + (r.url || "") + "\n" + (r.description || "")
    ).join("\n\n");
  },
};
