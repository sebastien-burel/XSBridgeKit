// A minimal XMLHttpRequest over the native __http(request, onChunk) primitive.
// Side-effect module: importing it installs globalThis.XMLHttpRequest. Supports
// the subset LLM providers need: open / setRequestHeader / send, onprogress
// (streamed body via responseText), onload / onerror, status, readyState.
// Response body arrives as chunks so SSE parsers can consume responseText
// incrementally.
globalThis.XMLHttpRequest = class XMLHttpRequest {
  constructor() {
    this.readyState = 0;
    this.status = 0;
    // Body pieces kept as an array, not a growing string: appending is O(1) and
    // there is no per-chunk full-body copy. `responseText` joins lazily (once,
    // for whole-body consumers); streaming parsers should call `readChunk()`.
    this._chunks = [];
    this._readIndex = 0;
    this._headers = {};
    this._responseHeaders = {};
    this.onprogress = null;
    this.onload = null;
    this.onerror = null;
    this.onreadystatechange = null;
  }
  // Full body received so far. O(total) — calling it per progress event would
  // be O(N²); a streaming parser should use `readChunk()` instead.
  get responseText() { return this._chunks.join(""); }
  // The text received since the previous call — O(delta). Lets an SSE parser
  // consume the stream incrementally without re-reading the whole body.
  readChunk() {
    if (this._readIndex >= this._chunks.length) return "";
    const parts = this._chunks.slice(this._readIndex);
    this._readIndex = this._chunks.length;
    return parts.join("");
  }
  _setState(s) {
    this.readyState = s;
    if (this.onreadystatechange) this.onreadystatechange();
  }
  open(method, url) {
    this._method = method;
    this._url = url;
    this._setState(1);
  }
  setRequestHeader(key, value) { this._headers[key] = value; }
  getAllResponseHeaders() {
    return Object.keys(this._responseHeaders)
      .map((k) => k + ": " + this._responseHeaders[k]).join("\r\n");
  }
  getResponseHeader(name) {
    const lower = String(name).toLowerCase();
    for (const k of Object.keys(this._responseHeaders)) {
      if (k.toLowerCase() === lower) return this._responseHeaders[k];
    }
    return null;
  }
  send(body) {
    const req = {
      method: this._method || "GET",
      url: this._url,
      headers: this._headers,
      body: body == null ? null : String(body),
    };
    __http(req, (chunk) => {
      this._chunks.push(chunk);
      this._setState(3);
      if (this.onprogress) this.onprogress();
    }).then((res) => {
      this.status = res.status;
      this._responseHeaders = res.headers || {};
      this._setState(4);
      if (this.onload) this.onload();
    }).catch((err) => {
      this.status = 0;
      this._setState(4);
      if (this.onerror) this.onerror(err);
    });
  }
  abort() {}
};
