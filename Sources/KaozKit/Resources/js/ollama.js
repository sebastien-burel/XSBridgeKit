// Ollama /api/chat (NDJSON stream, no auth). config: { model, baseURL }.
import "./xmlhttprequest.js";

function buildMessages(messages) {
  const out = [];
  for (const m of messages) {
    if (m.role === "system" || m.role === "user") {
      out.push({ role: m.role, content: m.content });
    } else if (m.role === "assistant") {
      out.push({ role: "assistant", content: m.content });
    } else if (m.role === "toolCall") {
      let args = {};
      try { args = JSON.parse(m.content || "{}"); } catch (e) {}
      const call = { function: { name: m.toolName, arguments: args } };
      const last = out[out.length - 1];
      if (last && last.role === "assistant") {
        if (!last.tool_calls) last.tool_calls = [];
        last.tool_calls.push(call);
      } else {
        out.push({ role: "assistant", content: "", tool_calls: [call] });
      }
    } else if (m.role === "toolResult") {
      out.push({ role: "tool", content: m.content });
    }
  }
  return out;
}

async function chat(req, onEvent) {
  const cfg = req.config || {};
  const base = (cfg.baseURL || "http://localhost:11434").replace(/\/+$/, "");
  const body = { model: cfg.model, stream: true, messages: buildMessages(req.messages || []) };
  if (req.tools && req.tools.length) {
    body.tools = req.tools.map((t) => ({
      type: "function",
      function: { name: t.name, description: t.description, parameters: t.input_schema },
    }));
  }

  await new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", base + "/api/chat");
    xhr.setRequestHeader("content-type", "application/json");

    let buffer = "";
    let counter = 0;
    function processLine(raw) {
      const line = raw.trim();
      if (!line) return;
      let ev; try { ev = JSON.parse(line); } catch (e) { return; }
      if (ev.error) { reject(new Error(String(ev.error))); return; }
      const msg = ev.message;
      if (msg) {
        if (msg.content) onEvent({ type: "textDelta", text: msg.content });
        if (msg.tool_calls) {
          for (const tc of msg.tool_calls) {
            const fn = tc.function || {};
            const args = typeof fn.arguments === "string"
              ? fn.arguments : JSON.stringify(fn.arguments || {});
            onEvent({ type: "toolCall", id: "call_" + (counter++), name: fn.name, arguments: args });
          }
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
      else reject(new Error("ollama HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
    };
    xhr.onerror = (e) => reject(new Error("network error: " + e));
    xhr.send(JSON.stringify(body));
  });
}

export default { chat };
