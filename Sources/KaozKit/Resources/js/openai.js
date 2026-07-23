// OpenAI Chat Completions (SSE stream) + OpenAI-compatible servers. baseURL
// includes the API version path (…/v1); "/chat/completions" is appended.
import "./xmlhttprequest.js";

function buildMessages(messages) {
  const out = [];
  for (const m of messages) {
    if (m.role === "system") { out.push({ role: "system", content: m.content }); continue; }
    if (m.role === "user") { out.push({ role: "user", content: m.content }); continue; }
    if (m.role === "assistant") { out.push({ role: "assistant", content: m.content }); continue; }
    if (m.role === "toolCall") {
      const tc = { id: m.toolCallID, type: "function",
                   function: { name: m.toolName, arguments: m.content || "{}" } };
      const last = out[out.length - 1];
      if (last && last.role === "assistant") {
        if (!last.tool_calls) last.tool_calls = [];
        last.tool_calls.push(tc);
      } else {
        out.push({ role: "assistant", content: null, tool_calls: [tc] });
      }
      continue;
    }
    if (m.role === "toolResult") {
      out.push({ role: "tool", tool_call_id: m.toolCallID, content: m.content });
      continue;
    }
  }
  return out;
}

async function chat(req, onEvent) {
  const cfg = req.config || {};
  // baseURL includes the API version path (…/v1, …/v4); we append the route.
  const base = (cfg.baseURL || "https://api.openai.com/v1").replace(/\/+$/, "");
  const body = {
    model: cfg.model, stream: true, messages: buildMessages(req.messages || []),
    stream_options: { include_usage: true },   // final chunk carries token usage
  };
  if (req.tools && req.tools.length) {
    body.tools = req.tools.map((t) => ({
      type: "function",
      function: { name: t.name, description: t.description, parameters: t.input_schema },
    }));
  }

  await new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", base + "/chat/completions");
    xhr.setRequestHeader("content-type", "application/json");
    xhr.setRequestHeader("authorization", "Bearer " + (cfg.apiKey || ""));

    let buffer = "";
    const toolCalls = {};

    function flushTools() {
      for (const i of Object.keys(toolCalls)) {
        const t = toolCalls[i];
        onEvent({ type: "toolCall", id: t.id || ("call_" + i), name: t.name, arguments: t.args || "{}" });
        delete toolCalls[i];
      }
    }
    function processLine(raw) {
      const line = raw.replace(/\r$/, "");
      if (!line.startsWith("data:")) return;
      const payload = line.slice(5).trim();
      if (!payload) return;
      if (payload === "[DONE]") { flushTools(); return; }
      let ev; try { ev = JSON.parse(payload); } catch (e) { return; }
      if (ev.usage) {
        onEvent({ type: "metrics", promptTokens: ev.usage.prompt_tokens,
                  completionTokens: ev.usage.completion_tokens });
      }
      const choice = ev.choices && ev.choices[0];
      if (!choice) return;   // usage-only final chunk has no choices
      const delta = choice.delta || {};
      if (delta.content) onEvent({ type: "textDelta", text: delta.content });
      if (delta.reasoning_content) onEvent({ type: "reasoningDelta", text: delta.reasoning_content });
      if (delta.tool_calls) {
        for (const tc of delta.tool_calls) {
          const i = tc.index || 0;
          if (!toolCalls[i]) toolCalls[i] = { id: "", name: "", args: "" };
          if (tc.id) toolCalls[i].id = tc.id;
          if (tc.function) {
            if (tc.function.name) toolCalls[i].name = tc.function.name;
            if (tc.function.arguments) toolCalls[i].args += tc.function.arguments;
          }
        }
      }
      if (choice.finish_reason === "tool_calls") flushTools();
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
      flushTools();
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else reject(new Error("openai HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
    };
    xhr.onerror = (e) => reject(new Error("network error: " + e));
    xhr.send(JSON.stringify(body));
  });
}

export default { chat };
