// AskModel.js - config/history/request/response logic for the Ask panel.
// All functions are pure JS so the QML UI stays about drawing.
// The API layer targets Ollama's native REST API (/api/chat, /api/tags),
// which is served both by a local Ollama daemon and by https://ollama.com
// for cloud models.

// Strip `//` comment lines from the JSONC config file. Comments must be on
// their own line (same rule as the bash version).
function stripComments(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim().indexOf("//") === 0) continue
    out.push(lines[i])
  }
  return out.join("\n")
}

// Parse the config file text into an object.
// Returns null on parse failure.
function parseConfig(text) {
  try {
    return JSON.parse(stripComments(text))
  } catch (e) {
    return null
  }
}

// The defaults written on first run.
function defaultConfig() {
  return {
    role: "You are a helpful assistant.",
    model: "",
    temperature: 0.4,
    top_p: 0.9,
    thinking: "enabled",
    num_ctx: 0,
    response_format: "text",
    save_history: "y",
    screensize: "medium",
    host: "http://localhost:11434",
    mode: "local"
  }
}

// Serialize a config object back to plain JSON text.
function serializeConfig(cfg) {
  return JSON.stringify(cfg, null, 2) + "\n"
}

// Merge a parsed config with defaults so missing keys never break the UI.
function withDefaults(cfg) {
  var def = defaultConfig()
  var merged = {}
  for (var key in def) merged[key] = def[key]
  if (cfg) for (var k in cfg) merged[k] = cfg[k]
  return merged
}

// Parse history.jsonl (one JSON object per line) into an array of messages.
function parseHistory(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      out.push(JSON.parse(line))
    } catch (e) {
      // skip malformed lines
    }
  }
  return out
}

// Group a history.jsonl text into exchanges: each user message followed by
// its assistant answer becomes one thread {question, answer}. An assistant
// message without a preceding user (or a trailing unanswered question) still
// yields a thread so nothing is dropped.
function parseThreads(text) {
  var hist = parseHistory(text)
  var threads = []
  var current = null
  for (var i = 0; i < hist.length; i++) {
    var m = hist[i]
    if (m.role === "user") {
      current = { question: String(m.content || ""), answer: "" }
      threads.push(current)
    } else if (m.role === "assistant") {
      if (current && current.answer === "") {
        current.answer = String(m.content || "")
        current = null
      } else {
        threads.push({ question: "", answer: String(m.content || "") })
      }
    }
  }
  return threads
}

// Build the `messages` array: system role, then history, then the new user
// question.
function buildMessages(cfg, history, question) {
  var messages = []
  var role = String(cfg.role || "").trim()
  if (role) messages.push({ role: "system", content: role })
  for (var i = 0; i < history.length; i++) {
    var m = history[i]
    if (m && m.role && m.content) messages.push(m)
  }
  messages.push({ role: "user", content: question })
  return messages
}

// Build the native Ollama request body from the config and messages.
// `stream: false` asks for a single JSON response instead of NDJSON.
function buildRequest(cfg, messages) {
  function num(v, fallback) {
    var n = parseFloat(v)
    return isNaN(n) ? fallback : n
  }
  var options = {
    temperature: num(cfg.temperature, 0.4),
    top_p: num(cfg.top_p, 0.9)
  }
  var nctx = parseInt(cfg.num_ctx, 10)
  if (!isNaN(nctx) && nctx > 0) options.num_ctx = nctx
  var req = {
    model: String(cfg.model || ""),
    messages: messages,
    stream: false,
    think: String(cfg.thinking || "enabled").toLowerCase() !== "disabled",
    options: options
  }
  if (String(cfg.response_format || "text") === "json_object") req.format = "json"
  return req
}

// Parse the raw /api/chat response body.
// Returns one of:
//   { answer: "..." }
//   { error: "..." }
//   { unexpected: <parsed object> }
function parseResponse(raw) {
  var data = null
  try {
    data = JSON.parse(raw)
  } catch (e) {
    return { error: "Invalid response from Ollama:\n" + raw }
  }
  if (data && data.message && typeof data.message.content === "string") {
    return { answer: data.message.content }
  }
  if (data && data.error) {
    return { error: "Ollama error: " + String(data.error) }
  }
  return { unexpected: data }
}

if (typeof module !== "undefined") {
  module.exports = {
  stripComments: stripComments,
  parseConfig: parseConfig,
  defaultConfig: defaultConfig,
  serializeConfig: serializeConfig,
  withDefaults: withDefaults,
  parseHistory: parseHistory,
  parseThreads: parseThreads,
  buildMessages: buildMessages,
  buildRequest: buildRequest,
  parseResponse: parseResponse
  }
}
