// Anthropic Messages API (SSE stream). config: { apiKey, model, baseURL? }.
import "./xmlhttprequest.js";

// Map our neutral ChatMessage[] to Anthropic's messages + system.
function buildMessages(messages) {
  let system = "";
  const out = [];
  for (const m of messages) {
    if (m.role === "system") { system += (system ? "\n" : "") + m.content; continue; }
    if (m.role === "user") { out.push({ role: "user", content: m.content }); continue; }
    if (m.role === "assistant") { out.push({ role: "assistant", content: m.content }); continue; }
    if (m.role === "toolCall") {
      let input = {};
      try { input = JSON.parse(m.content || "{}"); } catch (e) {}
      const block = { type: "tool_use", id: m.toolCallID, name: m.toolName, input };
      const last = out[out.length - 1];
      if (last && last.role === "assistant") {
        if (typeof last.content === "string") {
          last.content = last.content ? [{ type: "text", text: last.content }] : [];
        }
        last.content.push(block);
      } else {
        out.push({ role: "assistant", content: [block] });
      }
      continue;
    }
    if (m.role === "toolResult") {
      out.push({ role: "user", content: [{
        type: "tool_result",
        tool_use_id: m.toolCallID,
        content: m.content,
        is_error: !!m.toolIsError,
      }]});
      continue;
    }
  }
  return { system, messages: out };
}

async function chat(req, onEvent) {
  const cfg = req.config || {};
  const base = (cfg.baseURL || "https://api.anthropic.com").replace(/\/+$/, "");
  const built = buildMessages(req.messages || []);
  const body = {
    model: cfg.model,
    max_tokens: cfg.maxTokens || 4096,
    stream: true,
    messages: built.messages,
  };
  if (built.system) body.system = built.system;
  if (req.tools && req.tools.length) {
    body.tools = req.tools.map((t) => ({
      name: t.name, description: t.description, input_schema: t.input_schema,
    }));
  }

  await new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", base + "/v1/messages");
    xhr.setRequestHeader("content-type", "application/json");
    xhr.setRequestHeader("x-api-key", cfg.apiKey || "");
    xhr.setRequestHeader("anthropic-version", "2023-06-01");

    let buffer = "";
    const toolBlocks = {};

    function processLine(raw) {
      const line = raw.replace(/\r$/, "");
      if (!line.startsWith("data:")) return;
      const payload = line.slice(5).trim();
      if (!payload || payload === "[DONE]") return;
      let ev;
      try { ev = JSON.parse(payload); } catch (e) { return; }
      if (ev.type === "content_block_start" && ev.content_block && ev.content_block.type === "tool_use") {
        toolBlocks[ev.index] = { id: ev.content_block.id, name: ev.content_block.name, json: "" };
      } else if (ev.type === "content_block_delta" && ev.delta) {
        if (ev.delta.type === "text_delta") {
          onEvent({ type: "textDelta", text: ev.delta.text });
        } else if (ev.delta.type === "thinking_delta") {
          onEvent({ type: "reasoningDelta", text: ev.delta.thinking || "" });
        } else if (ev.delta.type === "input_json_delta") {
          const b = toolBlocks[ev.index];
          if (b) b.json += ev.delta.partial_json || "";
        }
      } else if (ev.type === "content_block_stop") {
        const b = toolBlocks[ev.index];
        if (b) {
          onEvent({ type: "toolCall", id: b.id, name: b.name, arguments: b.json || "{}" });
          delete toolBlocks[ev.index];
        }
      } else if (ev.type === "error") {
        reject(new Error((ev.error && ev.error.message) || "anthropic error"));
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
      else reject(new Error("anthropic HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
    };
    xhr.onerror = (e) => reject(new Error("network error: " + e));
    xhr.send(JSON.stringify(body));
  });
}

export default { chat };
