// Shared HTTP helper for JS tools, over the native XMLHttpRequest shim.
import "../xmlhttprequest.js"; // installs globalThis.XMLHttpRequest (needs native __http)

// GET `url` with optional headers. Resolves { status, text, contentType };
// rejects on a network (transport) error.
export function httpGet(url, headers) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("GET", url);
    const h = headers || {};
    for (const k of Object.keys(h)) xhr.setRequestHeader(k, h[k]);
    xhr.onload = () => resolve({
      status: xhr.status,
      text: xhr.responseText,
      contentType: (xhr.getResponseHeader("content-type") || "").toLowerCase(),
    });
    xhr.onerror = (e) => reject(new Error("network error: " + e));
    xhr.send(null);
  });
}
