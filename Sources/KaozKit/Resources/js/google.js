// Google Gemini :streamGenerateContent?alt=sse. config: { apiKey, model, baseURL? }.
import "./xmlhttprequest.js";

function sanitizeSchema(s) {
  if (Array.isArray(s)) return s.map(sanitizeSchema);
  if (s && typeof s === "object") {
    const out = {};
    for (const k of Object.keys(s)) {
      if (k === "additionalProperties" || k === "$schema" || k === "$id"
          || k === "$defs" || k === "definitions") continue;
      out[k] = sanitizeSchema(s[k]);
    }
    return out;
  }
  return s;
}

function buildContents(messages) {
  const nameByCallId = {};
  for (const m of messages) {
    if (m.role === "toolCall" && m.toolCallID) nameByCallId[m.toolCallID] = m.toolName;
  }
  const out = [];
  for (const m of messages) {
    if (m.role === "system") continue;
    if (m.role === "user") {
      out.push({ role: "user", parts: [{ text: m.content }] });
    } else if (m.role === "assistant") {
      if (m.content) out.push({ role: "model", parts: [{ text: m.content }] });
    } else if (m.role === "toolCall") {
      let args = {};
      try { args = JSON.parse(m.content || "{}"); } catch (e) {}
      const part = { functionCall: { name: m.toolName, args: args } };
      if (m.thoughtSignature) part.thoughtSignature = m.thoughtSignature;
      const last = out[out.length - 1];
      if (last && last.role === "model") last.parts.push(part);
      else out.push({ role: "model", parts: [part] });
    } else if (m.role === "toolResult") {
      const part = { functionResponse: {
        name: nameByCallId[m.toolCallID] || "",
        response: { content: m.content } } };
      const last = out[out.length - 1];
      if (last && last.role === "user" && last.parts[0] && last.parts[0].functionResponse) {
        last.parts.push(part);
      } else {
        out.push({ role: "user", parts: [part] });
      }
    }
  }
  return out;
}

async function chat(req, onEvent) {
  const cfg = req.config || {};
  const base = (cfg.baseURL || "https://generativelanguage.googleapis.com/v1beta")
    .replace(/\/+$/, "");
  const messages = req.messages || [];
  const systemBits = messages.filter((m) => m.role === "system").map((m) => m.content);
  const body = { contents: buildContents(messages) };
  if (systemBits.length) body.systemInstruction = { parts: [{ text: systemBits.join("\n\n") }] };
  if (req.tools && req.tools.length) {
    body.tools = [{ functionDeclarations: req.tools.map((t) => ({
      name: t.name, description: t.description, parameters: sanitizeSchema(t.input_schema),
    })) }];
  }

  await new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", base + "/models/" + encodeURIComponent(cfg.model)
      + ":streamGenerateContent?alt=sse");
    xhr.setRequestHeader("content-type", "application/json");
    xhr.setRequestHeader("x-goog-api-key", cfg.apiKey || "");

    let buffer = "", counter = 0;
    function processLine(raw) {
      const line = raw.replace(/\r$/, "");
      if (!line.startsWith("data:")) return;
      const payload = line.slice(5).trim();
      if (!payload) return;
      let ev; try { ev = JSON.parse(payload); } catch (e) { return; }
      if (ev.error) { reject(new Error((ev.error && ev.error.message) || "gemini error")); return; }
      const cand = ev.candidates && ev.candidates[0];
      const parts = (cand && cand.content && cand.content.parts) || [];
      for (const p of parts) {
        if (typeof p.text === "string") onEvent({ type: "textDelta", text: p.text });
        if (p.functionCall) {
          onEvent({ type: "toolCall", id: "call_" + (counter++),
            name: p.functionCall.name,
            arguments: JSON.stringify(p.functionCall.args || {}),
            thoughtSignature: p.thoughtSignature });
        }
      }
    }
    xhr.onprogress = () => {
      buffer += xhr.readChunk();
      let idx;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        processLine(buffer.slice(0, idx));
        buffer = buffer.slice(idx + 1);
      }
    };
    xhr.onload = () => {
      if (buffer) processLine(buffer);
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else reject(new Error("gemini HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
    };
    xhr.onerror = (e) => reject(new Error("network error: " + e));
    xhr.send(JSON.stringify(body));
  });
}

export default { chat };
