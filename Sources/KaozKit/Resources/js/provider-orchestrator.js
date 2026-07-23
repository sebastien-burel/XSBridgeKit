// Drives a JS-authored provider (globalThis.tyProvider.chat(request, onEvent))
// and bridges its outcome to Swift via the native __emit / __done /
// __providerError host functions. Side-effect module: importing it installs
// globalThis.__runProviderChat, which JSProvider calls per chat.
globalThis.__runProviderChat = function (requestJSON) {
  let req;
  try { req = JSON.parse(requestJSON); }
  catch (e) { __providerError("invalid provider request JSON"); return; }
  Promise.resolve()
    .then(() => {
      if (!globalThis.tyProvider || typeof globalThis.tyProvider.chat !== "function") {
        throw new Error("provider module did not define tyProvider.chat");
      }
      return globalThis.tyProvider.chat(req, (event) => { __emit(event); });
    })
    .then(() => { __done(); })
    .catch((err) => { __providerError(String((err && err.stack) || err)); });
};
