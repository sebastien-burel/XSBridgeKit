// The agent runtime orchestrator, installed on a TyKaoz agent engine. Side-
// effect module: importing it wires host.llm, globalThis.__runAgent (dynamic-
// imports the staged agent module and reports its result) and __callTool.
// `host` is a global installed by KaozHostC.
// A provider handle: `host.provider("mlx", { model }).chat(messages, { tools }, onToken)`.
// `id` selects the provider (omit for the run's default); extra opts (model,
// baseURL, …) are forwarded to the host's Swift resolver. Secrets (API keys)
// stay in Swift — never pass them from here.
host.provider = function (id, providerOpts) {
  providerOpts = providerOpts || {};
  return {
    chat: function (messages, opts, onToken) {
      if (typeof opts === 'function') { onToken = opts; opts = {}; }
      opts = opts || {};
      if (typeof onToken !== 'function') onToken = function () {};
      var selector = {};
      if (id !== undefined && id !== null) selector.id = id;
      for (var k in providerOpts) selector[k] = providerOpts[k];
      return host.__chat(messages, opts.tools || [], selector, onToken);
    }
  };
};

// The default handle (the run's configured provider). Keeps host.llm.chat(...).
host.llm = host.provider();

// Discovery: the provider ids/names the host exposes (set by Swift at startup).
host.providers = function () { return globalThis.__providerCatalog || []; };

globalThis.__runAgent = function (path, inputJSON) {
  var input = JSON.parse(inputJSON);
  import(path)
    .then(function (ns) {
      var run = (ns && (ns.run || ns.default)) || globalThis.run;
      if (typeof run !== 'function')
        throw new Error("l'agent ne définit pas run(input)");
      return run(input);
    })
    .then(function (r) {
      host.__report(JSON.stringify(r === undefined ? null : r));
    })
    .catch(function (e) {
      host.__fail(String((e && e.stack) || e));
    });
};

// Resident agent: load the module once and keep it alive. The default export
// may be an object of handlers ({ onMessage, onEvent, onTick }) or a plain
// run(input)/default function (legacy one-shot, treated as onMessage).
globalThis.__loadAgent = function (path) {
  globalThis.__agentReady = import(path).then(function (m) {
    globalThis.__agent = (m && (m.default || m)) || {};
  });
};

// Deliver one event to the resident agent and settle the host by deliveryId —
// WITHOUT ending the run (the engine stays alive for the next delivery).
globalThis.__deliver = function (kind, deliveryId, inputJSON) {
  var input = JSON.parse(inputJSON);
  Promise.resolve(globalThis.__agentReady)
    .then(function () {
      var a = globalThis.__agent || {};
      var fn;
      if (kind === 'message') fn = (typeof a === 'function') ? a : (a.onMessage || a.run);
      else if (kind === 'event') fn = a.onEvent;
      else if (kind === 'tick') fn = a.onTick;
      if (typeof fn !== 'function')
        throw new Error("l'agent n'a pas de handler pour '" + kind + "'");
      return fn.call(a, input);
    })
    .then(function (r) {
      host.__deliverResult(deliveryId, JSON.stringify(r === undefined ? null : r), false);
    })
    .catch(function (e) {
      host.__deliverResult(deliveryId, String((e && e.stack) || e), true);
    });
};

globalThis.__callTool = function (name, argsJSON, callId) {
  var list = globalThis.tools || [];
  var tool = list.find(function (t) { return t.name === name; });
  if (!tool || typeof tool.run !== 'function') {
    host.__toolResult(callId, null, 'unknown tool: ' + name);
    return;
  }
  Promise.resolve()
    .then(function () { return tool.run(JSON.parse(argsJSON)); })
    .then(function (r) {
      host.__toolResult(callId, JSON.stringify(r === undefined ? null : r), null);
    })
    .catch(function (e) {
      host.__toolResult(callId, null, String((e && e.stack) || e));
    });
};
