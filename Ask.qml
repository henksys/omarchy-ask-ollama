import QtQuick
import QtQuick.Controls
import QtQml.Models
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "AskModel.js" as AskModel

// Ask - chat with Ollama from the desktop.
// Works as an Omarchy shell plugin, summoned via the shell IPC.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/ask-ollama"
  readonly property string configFile: configDir + "/config"
  readonly property string keyFile: configDir + "/key"
  readonly property string headerFile: configDir + "/.header"
  readonly property string historyDir: home + "/.local/share/ask-ollama"
  readonly property string historyFile: historyDir + "/history.jsonl"

  property bool opened: false
  property bool loaded: false
  property bool busy: false
  property string currentTab: "ask"
  property var config: ({})
  property string lastQuestion: ""
  property string apiStdout: ""
  property string apiStderr: ""
  property bool apiStdoutDone: false
  property bool apiExited: false
  property int apiExitCode: 0
  property bool configReadDone: false
  property bool historyReadDone: false
  property bool savedFlash: false
  property bool restoredFlash: false
  property bool clearedFlash: false
  property bool copiedFlash: false
  property int scrollTicks: 0
  property string _historyText: ""
  property string _pendingSelection: ""

  // Settings-form scratch state (bound by the Settings tab controls).
  property string s_role: ""
  property string s_model: ""
  property real s_temperature: 0.4
  property real s_top_p: 0.9
  property string s_temperature_text: "0.40"
  property string s_top_p_text: "0.90"
  property bool s_thinking: true
  property string s_num_ctx_text: ""
  property string s_response_format: "text"
  property bool s_save_history: true
  property string s_screensize: "medium"

  // Connection tab state.
  property string s_mode: "local"
  property string s_host: ""
  property string connectionStatus: ""
  property bool connTesting: false
  property bool connDone: false
  property string s_api_key: ""
  property string apiKeyStatus: ""
  property string apiKeyFlashText: ""
  property bool apiKeyReadDone: false
  property bool keyReadDone: false
  property string _pendingConfig: ""
  property string _pendingHistory: ""
  property string _pendingBody: ""
  property string _pendingHeader: ""
  property string _pendingKey: ""
  property string _pendingRequestType: ""
  property string _pendingShowModel: ""

  // Model list state (fetched live from the Ollama /api/tags endpoint).
  // modelMeta maps a model name to { capabilities, context_length }.
  property var modelOptions: []
  property var modelMeta: ({})
  property bool modelLoading: false
  property string modelsError: ""

  readonly property string cloudBaseUrl: "https://ollama.com"

  readonly property bool saveHistory: String(root.config.save_history || "n").toLowerCase() === "y"

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(40), Style.font.title + Style.spacing.controlPaddingY * 2)

  // Height of the Omarchy top bar; "full" sits below it like a maximized
  // window, so the bar stays visible.
  readonly property int barHeight: Style.bar.sizeHorizontal

  // Panel size, driven by the "Screensize" setting:
  //   small  - about half the desktop (the original size)
  //   medium - small + 20 percentage points of the screen
  //   full   - full width, below the top bar (like a maximized window)
  property int cardWidth: {
    if (root.config.screensize === "full") return panel.width
    if (root.config.screensize === "medium")
      return Math.max(Style.space(320), Math.round(panel.width * 0.7))
    return Math.max(Style.space(320), Math.min(Style.space(920), Math.round(panel.width * 0.5)))
  }
  property int cardHeight: {
    if (root.config.screensize === "full") return panel.height - root.barHeight
    if (root.config.screensize === "medium")
      return Math.max(Style.space(240), Math.round(panel.height * 0.75))
    return Math.max(Style.space(240), Math.min(Style.space(760), Math.round(panel.height * 0.55)))
  }
  // "full" is anchored to the top below the bar (edge-to-edge); the other
  // sizes stay centered.
  property int cardX: root.config.screensize === "full" ? 0 : Math.round((panel.width - root.cardWidth) / 2)
  property int cardY: root.config.screensize === "full" ? root.barHeight : Math.round((panel.height - root.cardHeight) / 2)

  // ---- Lifecycle (same shape contract as Omarchy plugins) ----

  function open(payloadJson) {
    root.currentTab = "ask"
    root.opened = true
    root.sweepTempFiles()
    if (!root.loaded) {
      root.loadConfig()
    } else if (root.saveHistory) {
      root.loadHistoryIfEnabled()
    } else {
      threadModel.clear()
    }
    Qt.callLater(function() { inputField.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "henk.ask")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- Config ----

  // Descriptor-based safe read: open with O_NOFOLLOW|O_NONBLOCK so a symlink is
  // refused and a FIFO/device cannot block the open, verify a regular file via
  // fstat, and reject files larger than the cap instead of silently truncating.
  function safeReadCommand(path, cap) {
    return [
      "python3", "-c",
      "import os, stat, sys\n" +
      "p = sys.argv[1]\n" +
      "lim = int(sys.argv[2])\n" +
      "try:\n" +
      "    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)\n" +
      "except OSError:\n" +
      "    sys.exit(1)\n" +
      "try:\n" +
      "    st = os.fstat(fd)\n" +
      "    if not stat.S_ISREG(st.st_mode):\n" +
      "        sys.exit(1)\n" +
      "    data = os.read(fd, lim + 1)\n" +
      "    if len(data) > lim:\n" +
      "        sys.exit(2)\n" +
      "    sys.stdout.buffer.write(data)\n" +
      "finally:\n" +
      "    os.close(fd)\n",
      path, String(cap)
    ]
  }

  // Content is delivered over stdin (never argv/env); write to an
  // unpredictable same-directory temp file (0600) then atomically move it into
  // place (replaces a pre-planted symlink instead of following it). A trap
  // removes the temp if the write is interrupted (e.g. the shell restarts),
  // so stale .tmp.* files do not accumulate.
  function secureWriteStdinCommand(dir, target) {
    return [
      "bash", "-c",
      "install -d -m 700 \"$1\" && tmp=$(mktemp \"$1/.tmp.XXXXXX\") && trap 'rm -f \"$tmp\"' EXIT INT TERM HUP && chmod 600 \"$tmp\" && cat > \"$tmp\" && chmod 600 \"$tmp\" && mv -f \"$tmp\" \"$2\" && chmod 600 \"$2\"",
      "bash", dir, target
    ]
  }

  // Remove leftover temp files from interrupted writes. Anything older than a
  // minute is stale (writes take milliseconds), so an in-flight write is never
  // affected.
  function sweepTempFiles() {
    sweepProc.command = [
      "sh", "-c", 'find "$1" "$2" -maxdepth 1 -type f -name ".tmp.*" -mmin +1 -delete 2>/dev/null',
      "sh", root.configDir, root.historyDir
    ]
    sweepProc.running = true
  }

  function loadConfig() {
    root.configReadDone = false
    configReadProc.command = root.safeReadCommand(root.configFile, 1048576)
    configReadProc.running = true
  }

  function onConfigRead(text) {
    if (root.configReadDone) return
    root.configReadDone = true
    var parsed = AskModel.parseConfig(text)
    if (parsed && typeof parsed === "object") {
      root.config = AskModel.withDefaults(parsed)
    } else {
      // No usable config yet: adopt defaults and write the default file.
      root.config = AskModel.withDefaults(null)
      writeConfig(false)
    }
    root.loaded = true
    root.loadHistoryIfEnabled()
    // No model configured yet: fetch the installed models so the Ask tab
    // works without a Settings visit.
    if (root.safeModelId(root.config.model) === "") root.loadModels()
  }

  function writeConfig(showSaved) {
    var text = AskModel.serializeConfig(root.config)
    root._pendingConfig = text
    configWriteProc.stdinEnabled = true
    configWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.configFile)
    configWriteProc.running = true
    if (showSaved) {
      root.savedFlash = true
      savedTimer.restart()
    }
  }

  // ---- History ----

  function loadHistoryIfEnabled() {
    threadModel.clear()
    if (!root.saveHistory) {
      root._historyText = ""
      return
    }
    root.historyReadDone = false
    historyReadProc.command = root.safeReadCommand(root.historyFile, 8388608)
    historyReadProc.running = true
  }

  function onHistoryRead(text) {
    if (root.historyReadDone) return
    root.historyReadDone = true
    root._historyText = text
    var threads = AskModel.parseThreads(text)
    threadModel.clear()
    for (var i = 0; i < threads.length; i++) {
      threadModel.append({
        question: threads[i].question,
        answer: threads[i].answer,
        isError: false
      })
    }
    root.scrollToEnd()
  }

  function writeHistory(question, answer) {
    // Keep history in memory and rewrite the whole file atomically over stdin;
    // no append redirection, so no check-then-open race on the history file.
    root._historyText += JSON.stringify({ role: "user", content: question }) + "\n"
    root._historyText += JSON.stringify({ role: "assistant", content: answer }) + "\n"
    root._pendingHistory = root._historyText
    historyWriteProc.stdinEnabled = true
    historyWriteProc.command = root.secureWriteStdinCommand(root.historyDir, root.historyFile)
    historyWriteProc.running = true
  }

  // ---- Chat ----

  function scrollToEnd() {
    // Retry positionViewAtEnd a few times: the new delegate's height is only
    // known after the ListView lays it out, so a single call can fire before
    // the content grows and leave the view short of the end.
    root.scrollTicks = 0
    scrollTimer.restart()
  }

  // Open a new thread for the just-asked question (answer filled in later).
  function addQuestion(question) {
    threadModel.append({ question: question, answer: "", isError: false })
    root.scrollToEnd()
  }

  // Fill in the answer of the most recent thread, or the error text.
  function setLastAnswer(answer, isError) {
    var index = threadModel.count - 1
    if (index < 0) return
    threadModel.setProperty(index, "answer", answer)
    threadModel.setProperty(index, "isError", !!isError)
    root.scrollToEnd()
  }

  function clearHistory() {
    threadModel.clear()
    root._historyText = ""
    clearProc.command = ["sh", "-c", 'rm -f "$1"', "sh", root.historyFile]
    clearProc.running = true
    root.clearedFlash = true
    clearedTimer.restart()
  }

  // Copy a message to the clipboard (double-click on a question/answer).
  function copyAnswer(text) {
    Quickshell.clipboardText = String(text || "")
    root.copiedFlash = true
    copiedTimer.restart()
  }

  function send() {
    var question = inputField.text.trim()
    if (question === "" || root.busy) return
    if (root.safeModelId(root.config.model) === "") {
      root.setLastAnswer("No model selected. Open Settings and pick an Ollama model.", true)
      return
    }
    root.lastQuestion = question
    inputField.text = ""

    // One-shot mode: only the current exchange is shown.
    if (!root.saveHistory) threadModel.clear()

    root.addQuestion(question)
    root.busy = true
    root.apiStdout = ""
    root.apiStderr = ""
    root.apiStdoutDone = false
    root.apiExited = false
    root.apiExitCode = 0

    // The request body goes to curl over stdin; nothing sensitive is passed
    // as a command-line argument. curl enforces connect/time/size limits so
    // a stalled or oversized response cannot hang the shell.
    root._pendingBody = root.buildRequestBody(root.lastQuestion)
    if (root.effectiveMode() === "cloud") {
      // Cloud needs auth: read the key, write the Authorization header file
      // (0600, over stdin), then let headerWriteProc launch the request.
      root.keyReadDone = false
      keyReadProc.command = root.safeReadCommand(root.keyFile, 4096)
      keyReadProc.running = true
    } else {
      root.launchChatRequest()
    }
  }

  function onKeyRead(text) {
    if (root.keyReadDone) return
    root.keyReadDone = true
    var key = String(text || "").trim()
    if (!key) {
      root.busy = false
      root.setLastAnswer("No API key set. Open the Connection tab and save your Ollama Cloud API key.", true)
      Qt.callLater(function() { inputField.forceActiveFocus() })
      return
    }
    root._pendingHeader = "Authorization: Bearer " + key
    root._pendingRequestType = "chat"
    headerWriteProc.stdinEnabled = true
    headerWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.headerFile)
    headerWriteProc.running = true
  }

  // A model whose capabilities lack "thinking" must not be asked to think;
  // num_ctx is a local-only option and is omitted in cloud mode.
  function buildRequestBody(question) {
    var history = root.saveHistory ? AskModel.parseHistory(root._historyText) : []
    var msgs = AskModel.buildMessages(root.config, history, question)
    var cfg = root.config
    var noThink = !root.thinkingSupportedFor(cfg.model)
    var cloud = root.effectiveMode() === "cloud"
    if (noThink || cloud) {
      cfg = {}
      for (var k in root.config) cfg[k] = root.config[k]
      if (noThink) cfg.thinking = "disabled"
      if (cloud) cfg.num_ctx = 0
    }
    return JSON.stringify(AskModel.buildRequest(cfg, msgs))
  }

  function launchChatRequest() {
    apiProc.stdinEnabled = true
    if (root.effectiveMode() === "cloud") {
      apiProc.command = [
        "bash", "-c",
        "curl -s --connect-timeout 10 --max-time 300 --max-filesize 10485760 --proto '=https' -H \"@$2\" -H 'Content-Type: application/json' \"$1/api/chat\" -d @-",
        "bash", root.baseUrl(), root.headerFile
      ]
    } else {
      apiProc.command = [
        "bash", "-c",
        "curl -s --connect-timeout 10 --max-time 300 --max-filesize 10485760 --proto '=http,https' -H 'Content-Type: application/json' \"$1/api/chat\" -d @-",
        "bash", root.baseUrl()
      ]
    }
    apiProc.running = true
    apiWatchdog.restart()
  }

  function launchModelsRequest() {
    modelsProc.command = [
      "bash", "-c",
      "curl -s --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto '=http,https' \"$1/api/tags\"",
      "bash", root.baseUrl()
    ]
    modelsProc.running = true
    modelsWatchdog.restart()
  }

  function tryFinishApi() {
    if (root.apiStdoutDone && root.apiExited) root.finishApi(root.apiExitCode)
  }

  function finishApi(exitCode) {
    // Guarded by apiStdoutDone/apiExited so a single response is processed
    // exactly once regardless of stream-finished vs exited signal order.
    root.busy = false
    apiWatchdog.stop()
    if (exitCode !== 0 && root.apiStdout === "") {
      var msg
      if (exitCode === 7) msg = "Cannot reach Ollama at " + root.baseUrl() + " — is the service running?"
      else if (exitCode === 28) msg = "Request timed out."
      else if (exitCode === 63) msg = "Response too large."
      else if (exitCode === 18) msg = "Incomplete response from Ollama."
      else msg = "Request failed (exit " + exitCode + ").\n" + (root.apiStderr || "")
      root.setLastAnswer(msg, true)
    } else {
      var result = AskModel.parseResponse(root.apiStdout)
      if (result.answer !== undefined) {
        root.setLastAnswer(result.answer, false)
        if (root.saveHistory) root.writeHistory(root.lastQuestion, result.answer)
      } else if (result.error !== undefined) {
        root.setLastAnswer(result.error, true)
      } else {
        root.setLastAnswer("Unexpected API response:\n" + JSON.stringify(result.unexpected, null, 2), true)
      }
    }
    root.apiStdout = ""
    root.apiStderr = ""
    Qt.callLater(function() { inputField.forceActiveFocus() })
  }

  // ---- Settings form ----

  function loadSettings() {
    root.s_role = String(root.config.role || "")
    root.s_model = safeModelId(root.config.model)
    root.s_temperature = parseFloat(root.config.temperature) || 0.4
    root.s_top_p = parseFloat(root.config.top_p) || 0.9
    root.s_temperature_text = root.s_temperature.toFixed(2)
    root.s_top_p_text = root.s_top_p.toFixed(2)
    tempField.text = root.s_temperature_text
    topPField.text = root.s_top_p_text
    root.s_thinking = String(root.config.thinking || "enabled").toLowerCase() === "enabled"
    var nctx = parseInt(root.config.num_ctx, 10)
    if (isNaN(nctx) || nctx < 0) nctx = 0
    root.s_num_ctx_text = nctx > 0 ? String(nctx) : ""
    numCtxField.text = root.s_num_ctx_text
    root.s_response_format = String(root.config.response_format || "text")
    root.s_save_history = String(root.config.save_history || "y").toLowerCase() === "y"
    root.s_screensize = String(root.config.screensize || "medium")
    if (!root.thinkingSupported && root.s_thinking) root.s_thinking = false
  }

  function saveSettings() {
    var t = parseFloat(root.s_temperature)
    if (isNaN(t)) t = 0.4
    t = Math.min(2, Math.max(0, t))
    var p = parseFloat(root.s_top_p)
    if (isNaN(p)) p = 0.9
    p = Math.min(1, Math.max(0, p))
    root.s_temperature = t
    root.s_top_p = p
    var nctx = parseInt(String(root.s_num_ctx_text).trim(), 10)
    if (isNaN(nctx) || nctx < 0) nctx = 0
    root.s_num_ctx_text = nctx > 0 ? String(nctx) : ""
    root.config = {
      role: root.s_role.trim(),
      model: root.s_model,
      temperature: root.s_temperature,
      top_p: root.s_top_p,
      thinking: (root.s_thinking && root.thinkingSupported) ? "enabled" : "disabled",
      num_ctx: nctx,
      response_format: root.s_response_format,
      save_history: root.s_save_history ? "y" : "n",
      screensize: root.s_screensize,
      host: String(root.config.host || "http://localhost:11434"),
      mode: root.effectiveMode()
    }
    root.writeConfig(true)
    root.loadHistoryIfEnabled()
  }

  // Restore the default config: overwrite the form, write it to the config
  // file, and apply it immediately. History starts fresh, so the in-memory
  // thread is cleared and the history file is deleted.
  function restoreDefaults() {
    root.config = AskModel.defaultConfig()
    root.loadSettings()
    root.writeConfig(false)
    threadModel.clear()
    root._historyText = ""
    clearProc.command = ["sh", "-c", 'rm -f "$1"', "sh", root.historyFile]
    clearProc.running = true
    root.restoredFlash = true
    restoredTimer.restart()
  }

  // ---- Host / connection ----

  // Normalize user input into a scheme-qualified URL without trailing slash.
  function normalizeHost(v) {
    var s = String(v || "").trim()
    if (s === "") return "http://localhost:11434"
    if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(s)) s = "http://" + s
    while (s.length > 1 && s.charAt(s.length - 1) === "/") s = s.substring(0, s.length - 1)
    return s
  }

  // http:// is only acceptable for loopback; remote hosts must use https://.
  function hostError(v) {
    var s = root.normalizeHost(v)
    if (!/^https?:\/\//.test(s)) return "Host must start with http:// or https://"
    if (/\s/.test(s)) return "Host cannot contain spaces."
    if (/^http:\/\//.test(s)) {
      var rest = s.substring(7)
      var slash = rest.indexOf("/")
      if (slash !== -1) rest = rest.substring(0, slash)
      var host = rest
      if (host.charAt(0) === "[") host = host.substring(0, host.indexOf("]") + 1)
      else if (host.indexOf(":") !== -1) host = host.substring(0, host.indexOf(":"))
      if (host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && host !== "[::1]")
        return "http:// is only allowed for localhost; use https:// for remote hosts."
    }
    return ""
  }

  // Effective mode: "cloud" only when explicitly configured, otherwise local.
  function effectiveMode() {
    return String(root.config.mode || "local") === "cloud" ? "cloud" : "local"
  }

  // The base URL for API calls: the fixed ollama.com base in cloud mode, the
  // configured (and validated) host otherwise.
  function baseUrl() {
    if (root.effectiveMode() === "cloud") return root.cloudBaseUrl
    return root.normalizeHost(root.config.host)
  }

  // A model whose /api/tags (or /api/show) entry lacks the "thinking"
  // capability must not be asked to think. Unknown metadata is treated as
  // capable, so an unprobed model can still be used.
  function thinkingSupportedFor(name) {
    var m = root.modelMeta[String(name || "")]
    if (!m || !Array.isArray(m.capabilities) || m.capabilities.length === 0) return true
    return m.capabilities.indexOf("thinking") !== -1
  }

  readonly property bool thinkingSupported: root.thinkingSupportedFor(root.s_model)

  // ---- Connection tab ----

  function loadConnectionSettings() {
    root.s_mode = root.effectiveMode()
    root.s_host = String(root.config.host || "http://localhost:11434")
    root.connectionStatus = ""
    root.connDone = false
    root.connTesting = false
    // Read the stored key first so Test and Save act on the current value.
    root.apiKeyReadDone = false
    apiKeyReadProc.command = root.safeReadCommand(root.keyFile, 4096)
    apiKeyReadProc.running = true
  }

  function onApiKeyFileRead(text) {
    if (root.apiKeyReadDone) return
    root.apiKeyReadDone = true
    root.s_api_key = String(text || "").trim()
    root.testConnection()
  }

  function saveConnection() {
    if (root.s_mode === "local") {
      var err = root.hostError(root.s_host)
      if (err !== "") {
        root.connectionStatus = err
        return false
      }
      root.s_host = root.normalizeHost(root.s_host)
    }
    var cfg = {}
    for (var k in root.config) cfg[k] = root.config[k]
    cfg.mode = root.s_mode
    if (root.s_mode === "local") cfg.host = root.s_host
    root.config = cfg
    root.writeConfig(true)
    root.loadModels()
    return true
  }

  function saveApiKey() {
    var key = String(root.s_api_key || "").trim()
    if (key === "") {
      root.apiKeyStatus = "Enter an API key first."
      return
    }
    root._pendingKey = key
    keyWriteProc.stdinEnabled = true
    keyWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.keyFile)
    keyWriteProc.running = true
    root.apiKeyStatus = "Saved to " + root.keyFile + " with owner-only permissions (600)."
    root.apiKeyFlashText = "Saved"
    apiKeyTimer.restart()
  }

  function removeApiKey() {
    root.s_api_key = ""
    clearProc.command = ["sh", "-c", 'rm -f "$1"', "sh", root.keyFile]
    clearProc.running = true
    root.apiKeyStatus = "Stored key removed."
    root.apiKeyFlashText = "Removed"
    apiKeyTimer.restart()
  }

  // Cloud: /api/tags confirms reachability and /api/me (with the key) reports
  // the account. Local: /api/version plus the daemon's sign-in state.
  function testConnection() {
    root.connTesting = true
    root.connDone = false
    if (root.s_mode === "cloud") {
      root.connectionStatus = "Testing " + root.cloudBaseUrl + " ..."
      var key = String(root.s_api_key || "").trim()
      if (key !== "") {
        root._pendingHeader = "Authorization: Bearer " + key
        root._pendingRequestType = "connection"
        headerWriteProc.stdinEnabled = true
        headerWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.headerFile)
        headerWriteProc.running = true
        return
      }
      root.launchConnRequest("")
      return
    }
    var err = root.hostError(root.s_host)
    if (err !== "") {
      root.connTesting = false
      root.connectionStatus = err
      return
    }
    var host = root.normalizeHost(root.s_host)
    root.connectionStatus = "Testing " + host + " ..."
    connProc.command = [
      "bash", "-c",
      "u=\"${1%/}\"; v=$(curl -s --connect-timeout 3 --max-time 6 --proto '=http,https' \"$u/api/version\" 2>/dev/null) || true; if [ -z \"$v\" ]; then exit 7; fi; printf '%s\\n' \"$v\"; curl -s --connect-timeout 3 --max-time 6 --proto '=http,https' -X POST \"$u/api/me\" 2>/dev/null || true",
      "bash", host
    ]
    connProc.running = true
  }

  // $1 = "" for keyless, otherwise the 0600 header file path to authenticate.
  function launchConnRequest(headerPath) {
    var useHeader = headerPath !== "" && headerPath !== undefined && headerPath !== null
    if (useHeader) {
      connProc.command = [
        "bash", "-c",
        "u=\"${1%/}\"; t=$(curl -s --connect-timeout 3 --max-time 6 --proto '=https' \"$u/api/tags\" 2>/dev/null) || true; if [ -z \"$t\" ]; then exit 7; fi; printf '%s\\n' \"$t\"; curl -s --connect-timeout 3 --max-time 6 --proto '=https' -H \"@$2\" -X POST \"$u/api/me\" 2>/dev/null || true",
        "bash", root.cloudBaseUrl, String(headerPath)
      ]
    } else {
      connProc.command = [
        "bash", "-c",
        "u=\"${1%/}\"; t=$(curl -s --connect-timeout 3 --max-time 6 --proto '=https' \"$u/api/tags\" 2>/dev/null) || true; if [ -z \"$t\" ]; then exit 7; fi; printf '%s\\n' \"$t\"",
        "bash", root.cloudBaseUrl
      ]
    }
    connProc.running = true
  }

  function onConnectionTest(text) {
    if (root.connDone) return
    root.connDone = true
    root.connTesting = false
    var lines = String(text || "").split("\n")
    if (root.s_mode === "cloud") {
      var tags = null
      try { tags = JSON.parse(lines[0]) } catch (e) { tags = null }
      if (!tags || !Array.isArray(tags.models)) {
        root.connectionStatus = "Cannot reach " + root.cloudBaseUrl + " — check your connection."
        return
      }
      var me = null
      try { me = JSON.parse(lines[1] || "") } catch (e) { me = null }
      var name = me ? String(me.Name || me.name || me.Email || me.email || "") : ""
      var plan = me ? String(me.Plan || me.plan || "") : ""
      if (name !== "") {
        root.connectionStatus = "Connected to " + root.cloudBaseUrl + " — signed in as " + name + (plan ? " (" + plan + ")" : "")
      } else {
        root.connectionStatus = root.cloudBaseUrl + " reachable — " + tags.models.length + " models listed. Save an API key to chat."
      }
      return
    }
    var ver = null
    try { ver = JSON.parse(lines[0]) } catch (e) { ver = null }
    if (!ver || typeof ver.version !== "string") {
      root.connectionStatus = "Cannot reach Ollama at " + root.baseUrl() + " — is the service running?"
      return
    }
    var status = "Ollama " + ver.version + " at " + root.baseUrl()
    var meLocal = null
    try { meLocal = JSON.parse(lines[1] || "") } catch (e) { meLocal = null }
    if (meLocal && (meLocal.email || meLocal.name)) {
      status += " — signed in as " + String(meLocal.name || meLocal.email) + (meLocal.plan ? " (" + String(meLocal.plan) + ")" : "")
    } else {
      status += " — not signed in (cloud models need ollama signin)"
    }
    root.connectionStatus = status
  }

  // ---- Model list ----

  // Ollama names may include tags and namespaces, e.g. "qwen3.5:4b" or
  // "library/model:tag". The value only ever travels inside JSON, so this is
  // a sanity check, not a shell-escaping measure.
  function safeModelId(v) {
    var s = String(v || "")
    return /^[a-zA-Z0-9][a-zA-Z0-9._:\/-]{0,127}$/.test(s) ? s : ""
  }

  function fallbackModelOptions() {
    var cur = safeModelId(root.s_model || root.config.model)
    return cur === "" ? [] : [{ value: cur, label: cur }]
  }

  function loadModels() {
    root.modelLoading = true
    root.modelsError = ""
    root.launchModelsRequest()
  }

  function onModelsResponse(text) {
    root.modelLoading = false
    modelsWatchdog.stop()
    var localMode = root.effectiveMode() === "local"
    var opts = []
    var meta = {}
    try {
      var data = JSON.parse(text)
      if (data && Array.isArray(data.models)) {
        for (var i = 0; i < data.models.length; i++) {
          var m = data.models[i]
          var name = safeModelId(m && m.name)
          if (name === "") continue
          var caps = Array.isArray(m.capabilities) ? m.capabilities : []
          // Skip embedding-only models when the daemon reports capabilities.
          if (caps.length > 0 && caps.indexOf("completion") === -1) continue
          meta[name] = {
            capabilities: caps,
            context_length: (m.details && parseInt(m.details.context_length, 10)) || 0
          }
          // Only local mode mixes cloud entries into the daemon's model list.
          var isCloud = localMode && !!(m.remote_host || m.remote_model)
          opts.push({ value: name, label: isCloud ? name + " (cloud)" : name })
        }
      }
    } catch (e) {
      opts = []
    }
    if (opts.length === 0) {
      root.modelsError = localMode
        ? "No Ollama models found. Pull one with ollama pull <model>."
        : "Could not fetch the model list from " + root.cloudBaseUrl + "."
      root.modelOptions = root.fallbackModelOptions()
      root.modelMeta = {}
      return
    }
    root.modelMeta = meta
    root.modelOptions = opts
    // Keep the configured model when it is available; otherwise select the
    // first one so the Ask tab works without a Settings visit.
    var current = safeModelId(root.s_model || root.config.model)
    var found = false
    for (var j = 0; j < opts.length; j++) if (opts[j].value === current) found = true
    if (!found) {
      root.s_model = opts[0].value
      var cfg = {}
      for (var k in root.config) cfg[k] = root.config[k]
      cfg.model = root.s_model
      root.config = cfg
    }
    root.loadModelInfo(safeModelId(root.s_model || root.config.model))
  }

  // Cloud mode: /api/tags carries no capabilities, but /api/show is public
  // and reports them (plus the context length). Fetch it for the selected
  // model so the Thinking toggle can be gated exactly like local mode.
  function loadModelInfo(model) {
    var id = safeModelId(model)
    if (id === "" || root.effectiveMode() !== "cloud") return
    root._pendingShowModel = id
    var body = JSON.stringify({ model: id })
    showProc.command = [
      "bash", "-c",
      "curl -s --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto '=https' -H 'Content-Type: application/json' --data \"$2\" \"$1/api/show\"",
      "bash", root.cloudBaseUrl, body
    ]
    showProc.running = true
  }

  function contextLengthFromShow(data) {
    if (!data || !data.model_info) return 0
    for (var k in data.model_info) {
      if (k.length > 15 && k.lastIndexOf(".context_length") === k.length - 15) {
        var v = parseInt(data.model_info[k], 10)
        if (!isNaN(v) && v > 0) return v
      }
    }
    return 0
  }

  function onShowResponse(text) {
    var model = root._pendingShowModel
    if (model === "") return
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    if (!data || !Array.isArray(data.capabilities)) return
    var meta = {}
    for (var k in root.modelMeta) meta[k] = root.modelMeta[k]
    meta[model] = {
      capabilities: data.capabilities,
      context_length: root.contextLengthFromShow(data)
    }
    root.modelMeta = meta
    // Switching to a model without the thinking capability turns the toggle
    // off, matching what the local `/api/tags` metadata path does.
    if (model === root.s_model && !root.thinkingSupportedFor(model)) root.s_thinking = false
  }

  // ---- IO processes ----

  Process {
    id: configReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onConfigRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.configReadDone) root.onConfigRead("")
    }
  }

  Process {
    id: historyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onHistoryRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.historyReadDone) root.onHistoryRead("")
    }
  }

  Process {
    id: keyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onKeyRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.keyReadDone) root.onKeyRead("")
    }
  }

  Process {
    id: apiKeyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onApiKeyFileRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.apiKeyReadDone) root.onApiKeyFileRead("")
    }
  }

  Process {
    id: modelsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onModelsResponse(String(text || ""))
    }
    onExited: function(code) {
      modelsWatchdog.stop()
      if (root.modelLoading) {
        root.modelLoading = false
        root.modelsError = "Could not fetch the model list from " + root.baseUrl() + "."
        root.modelOptions = root.fallbackModelOptions()
      }
    }
  }

  Process {
    id: showProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onShowResponse(String(text || ""))
    }
    onExited: function(code) {
      // Empty handler: a Process without any signal handler is not reliably
      // started, so keep this hook to guarantee the fetch actually runs.
    }
  }

  Process {
    id: connProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onConnectionTest(String(text || ""))
    }
    onExited: function(code) {
      if (!root.connDone) root.onConnectionTest("")
    }
  }

  Process {
    id: apiProc
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.apiStdout = String(text || "")
        root.apiStdoutDone = true
        root.tryFinishApi()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apiStderr = String(text || "").trim()
    }
    onStarted: function() {
      apiProc.write(root._pendingBody)
      apiProc.stdinEnabled = false
    }
    onExited: function(code) {
      root.apiExitCode = code
      root.apiExited = true
      root.tryFinishApi()
    }
  }

  Process {
    id: historyWriteProc
    stdinEnabled: true
    onStarted: function() {
      historyWriteProc.write(root._pendingHistory)
      historyWriteProc.stdinEnabled = false
    }
  }

  Process {
    id: configWriteProc
    stdinEnabled: true
    onStarted: function() {
      configWriteProc.write(root._pendingConfig)
      configWriteProc.stdinEnabled = false
    }
  }

  Process {
    id: keyWriteProc
    stdinEnabled: true
    onStarted: function() {
      keyWriteProc.write(root._pendingKey)
      keyWriteProc.stdinEnabled = false
    }
  }

  Process {
    id: headerWriteProc
    stdinEnabled: true
    onStarted: function() {
      headerWriteProc.write(root._pendingHeader)
      headerWriteProc.stdinEnabled = false
    }
    onExited: function(code) {
      var t = root._pendingRequestType
      root._pendingRequestType = ""
      if (code !== 0) {
        if (t === "connection") {
          root.connTesting = false
          root.connectionStatus = "Could not prepare the request."
        } else {
          root.busy = false
          root.setLastAnswer("Could not prepare the request.", true)
          Qt.callLater(function() { inputField.forceActiveFocus() })
        }
        return
      }
      if (t === "connection") root.launchConnRequest(root.headerFile)
      else root.launchChatRequest()
    }
  }

  Process {
    id: clearProc
    onExited: function(code) {
      // Empty handler: a Process without any signal handler is not reliably
      // started, so keep this hook to guarantee the rm actually runs.
    }
  }

  Process {
    id: sweepProc
    onExited: function(code) {
      // Empty handler: a Process without any signal handler is not reliably
      // started, so keep this hook to guarantee the sweep actually runs.
    }
  }

  // One row per exchange: { question, answer, isError }. Grouping each
  // question with its answer keeps the conversation readable as a thread.
  property ListModel threadModel: ListModel {}

  Timer {
    id: scrollTimer
    interval: 60
    repeat: true
    onTriggered: {
      chatList.positionViewAtEnd()
      root.scrollTicks++
      if (root.scrollTicks >= 6) scrollTimer.stop()
    }
  }

  Timer {
    id: savedTimer
    interval: 1600
    onTriggered: root.savedFlash = false
  }

  Timer {
    id: restoredTimer
    interval: 1600
    onTriggered: root.restoredFlash = false
  }

  Timer {
    id: clearedTimer
    interval: 1600
    onTriggered: root.clearedFlash = false
  }

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copiedFlash = false
  }

  Timer {
    id: copyTimer
    interval: 200
    onTriggered: {
      if (root._pendingSelection !== "") {
        root.copyAnswer(root._pendingSelection)
        root._pendingSelection = ""
      }
    }
  }

  // Watchdogs: curl enforces its own --max-time / --max-filesize, but these
  // guarantee the Process is torn down even if it never exits (e.g. failed to
  // start) so the shell can never hang on a request.
  Timer {
    id: apiWatchdog
    interval: 310000
    onTriggered: {
      if (!root.busy) return
      apiProc.signal(9)
      root.busy = false
      root.apiStdout = ""
      root.apiStderr = ""
      root.setLastAnswer("Request timed out.", true)
      Qt.callLater(function() { inputField.forceActiveFocus() })
    }
  }

  Timer {
    id: modelsWatchdog
    interval: 35000
    onTriggered: {
      root.modelLoading = false
      root.modelsError = "Could not fetch the model list (timed out)."
      root.modelOptions = root.fallbackModelOptions()
    }
  }

  Timer {
    id: apiKeyTimer
    interval: 1600
    onTriggered: root.apiKeyFlashText = ""
  }

  // ---- Window ----

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "henk-ask-ollama"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      x: root.cardX
      y: root.cardY
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.currentTab === "settings" || root.currentTab === "connection" || root.currentTab === "about") {
              root.currentTab = "ask"
              event.accepted = true
              return
            }
            root.dismiss()
            event.accepted = true
          }
        }

        Item {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset

        // ---- Header: tabs + close ----
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.headerHeight

          Button {
            id: askTabButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Ask"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "ask"
            focusable: true
            onClicked: root.currentTab = "ask"
          }

          Button {
            id: settingsTabButton
            anchors.left: askTabButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "Settings"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "settings"
            focusable: true
            onClicked: {
              root.loadSettings()
              root.loadModels()
              root.currentTab = "settings"
            }
          }

          Button {
            id: connectionTabButton
            anchors.left: settingsTabButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "Connection"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "connection"
            focusable: true
            onClicked: {
              root.loadConnectionSettings()
              root.currentTab = "connection"
            }
          }

          Button {
            id: aboutTabButton
            anchors.left: connectionTabButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "About"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "about"
            focusable: true
            onClicked: root.currentTab = "about"
          }

          Button {
            id: closeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Close"
            fontFamily: Style.font.family
            fontSize: Style.font.body
            focusable: true
            onClicked: root.dismiss()
          }

          // Program name, centered in the gap between About and Close.
          Text {
            id: headerTitle
            anchors.left: aboutTabButton.right
            anchors.right: closeButton.left
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: (root.manifest && root.manifest.name) || "Ask Ollama"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            font.underline: true
            elide: Text.ElideRight
          }
        }

        PanelSeparator {
          id: separator
          anchors.top: header.bottom
          anchors.left: parent.left
          anchors.right: parent.right
        }

        Item {
          id: contentArea
          anchors.top: separator.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.topMargin: Style.spacing.xl

          // ---- Ask tab ----
          Item {
            id: askContent
            anchors.fill: parent
            visible: root.currentTab === "ask"

            ListView {
              id: chatList
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: inputRow.top
              anchors.bottomMargin: Style.spacing.xxl
              clip: true
              spacing: Style.spacing.xxs
              boundsBehavior: Flickable.StopAtBounds
              model: threadModel
              delegate: threadDelegate
            }

            Row {
              id: inputRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.spacing.xxl
              height: Style.spacing.controlHeight

              TextField {
                id: inputField
                width: parent.width - sendButton.width - clearButton.width - parent.spacing * 2
                height: Style.spacing.controlHeight
                placeholderText: root.busy ? "Waiting for Ollama..." : "Ask Ollama..."
                enabled: !root.busy
                onAccepted: root.send()
              }

              Button {
                id: sendButton
                width: Style.space(96)
                height: Style.spacing.controlHeight
                text: root.busy ? "..." : "Send"
                fontFamily: Style.font.family
                fontSize: Style.font.body
                focusable: true
                enabled: !root.busy
                onClicked: root.send()
              }

              Button {
                id: clearButton
                width: Style.space(96)
                height: Style.spacing.controlHeight
                text: "Clear"
                fontFamily: Style.font.family
                fontSize: Style.font.body
                focusable: true
                enabled: !root.busy && threadModel.count > 0
                onClicked: root.clearHistory()
              }
            }

            Rectangle {
              visible: root.clearedFlash
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: inputRow.top
              anchors.bottomMargin: Style.spacing.md
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, root.accent)
              implicitWidth: clearedLabel.implicitWidth + Style.spacing.xxl * 2
              implicitHeight: clearedLabel.implicitHeight + Style.spacing.xxs * 2
              z: 3

              Text {
                id: clearedLabel
                anchors.centerIn: parent
                text: "History cleared"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Rectangle {
              visible: root.copiedFlash
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: inputRow.top
              anchors.bottomMargin: Style.spacing.md
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, root.accent)
              implicitWidth: copiedLabel.implicitWidth + Style.spacing.xxl * 2
              implicitHeight: copiedLabel.implicitHeight + Style.spacing.xxs * 2
              z: 3

              Text {
                id: copiedLabel
                anchors.centerIn: parent
                text: "Copied to clipboard"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---- Settings tab ----
          Item {
            id: settingsContent
            anchors.fill: parent
            visible: root.currentTab === "settings"

            Flickable {
              id: settingsScroll
              anchors.fill: parent
              contentHeight: settingsColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AlwaysOff }

              Column {
                id: settingsColumn
                width: settingsScroll.width
                spacing: Style.spacing.panelGap

                // Screensize
                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Screensize"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_screensize
                    options: ["small", "medium", "full"]
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.s_screensize = v }
                  }
                }

                // Role
                Column {
                  width: parent.width
                  spacing: Style.spacing.labelGap
                  Text {
                    text: "Role / system prompt"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                  }
                  TextField {
                    width: parent.width
                    text: root.s_role
                    placeholderText: "You are a helpful assistant."
                    onTextEdited: root.s_role = text
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Model"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Button {
                    id: modelsRefreshButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Refresh"
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    focusable: true
                    enabled: !root.modelLoading
                    onClicked: root.loadModels()
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_model
                    options: root.modelOptions
                    anchors.right: modelsRefreshButton.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) {
                      root.s_model = v
                      root.loadModelInfo(v)
                      if (!root.thinkingSupportedFor(v)) root.s_thinking = false
                    }
                  }
                }

                Text {
                  visible: root.modelLoading || root.modelsError !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.modelLoading ? "Loading models..." : root.modelsError
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Thinking"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.s_thinking
                    interactive: root.thinkingSupported
                    opacity: root.thinkingSupported ? 1 : 0.5
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.s_thinking = !root.s_thinking
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Context length (num_ctx)"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TextField {
                    id: numCtxField
                    width: Style.space(140)
                    height: Style.spacing.controlHeight
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "model default"
                    enabled: root.effectiveMode() !== "cloud"
                    opacity: root.effectiveMode() === "cloud" ? 0.5 : 1
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: RegularExpressionValidator { regularExpression: /^\d{0,7}$/ }
                    onTextEdited: root.s_num_ctx_text = text
                    onEditingFinished: {
                      var v = parseInt(root.s_num_ctx_text, 10)
                      if (isNaN(v) || v < 0) v = 0
                      root.s_num_ctx_text = v > 0 ? String(v) : ""
                      numCtxField.text = root.s_num_ctx_text
                    }
                  }
                }

                Text {
                  visible: root.effectiveMode() === "cloud"
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "num_ctx applies to local models only."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: {
                    var info = root.modelMeta[root.s_model]
                    return info !== undefined && info.context_length > 0
                  }
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: {
                    var info = root.modelMeta[root.s_model]
                    var max = (info && info.context_length) ? info.context_length : 0
                    if (max <= 0) return ""
                    return root.effectiveMode() === "cloud"
                      ? "This model supports up to " + max + " tokens."
                      : "This model supports up to " + max + " tokens. Blank keeps the model default."
                  }
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Temperature"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TextField {
                    id: tempField
                    width: Style.space(140)
                    height: Style.spacing.controlHeight
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "0.40"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    validator: RegularExpressionValidator { regularExpression: /^\d*\.?\d{0,2}$/ }
                    onTextEdited: {
                      root.s_temperature_text = text
                      var v = parseFloat(text)
                      if (!isNaN(v)) root.s_temperature = v
                    }
                    onEditingFinished: {
                      var v = parseFloat(root.s_temperature_text)
                      if (isNaN(v)) v = root.s_temperature
                      v = Math.min(2, Math.max(0, v))
                      root.s_temperature = v
                      root.s_temperature_text = v.toFixed(2)
                      tempField.text = root.s_temperature_text
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Top P"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TextField {
                    id: topPField
                    width: Style.space(140)
                    height: Style.spacing.controlHeight
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "0.90"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    validator: RegularExpressionValidator { regularExpression: /^\d*\.?\d{0,2}$/ }
                    onTextEdited: {
                      root.s_top_p_text = text
                      var v = parseFloat(text)
                      if (!isNaN(v)) root.s_top_p = v
                    }
                    onEditingFinished: {
                      var v = parseFloat(root.s_top_p_text)
                      if (isNaN(v)) v = root.s_top_p
                      v = Math.min(1, Math.max(0, v))
                      root.s_top_p = v
                      root.s_top_p_text = v.toFixed(2)
                      topPField.text = root.s_top_p_text
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Output format"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_response_format
                    options: [
                      { value: "text", label: "text" },
                      { value: "json_object", label: "json_object" }
                    ]
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.s_response_format = v }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Save conversation history"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.s_save_history
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.s_save_history = !root.s_save_history
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "With history enabled, follow-up questions keep context and the chat shows past exchanges from " + root.historyFile + ". Disabled keeps each question one-shot."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                PanelSeparator {
                  width: parent.width
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight * 2 + Style.spacing.md

                  Button {
                    id: restoreButton
                    anchors.right: parent.right
                    anchors.top: parent.top
                    text: "Restore defaults"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.restoreDefaults()
                  }

                  Text {
                    visible: root.restoredFlash
                    text: "Restored"
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.right: restoreButton.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: restoreButton.verticalCenter
                  }

                  Button {
                    id: saveButton
                    anchors.right: parent.right
                    anchors.top: restoreButton.bottom
                    anchors.topMargin: Style.spacing.md
                    text: "Save settings"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.saveSettings()
                  }

                  Text {
                    visible: root.savedFlash
                    text: "Saved"
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.right: saveButton.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: saveButton.verticalCenter
                  }
                }

                Item { width: 1; height: Style.spacing.xs }
              }
            }
          }

          // ---- Connection tab ----
          Item {
            id: connectionContent
            anchors.fill: parent
            visible: root.currentTab === "connection"

            Flickable {
              id: connectionScroll
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: connectionWarning.top
              anchors.bottomMargin: Style.spacing.panelGap
              contentHeight: connectionColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: connectionColumn
                width: connectionScroll.width
                spacing: Style.spacing.panelGap

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Choose where the panel talks to. Local uses your own Ollama server; Cloud talks directly to ollama.com and needs no local install. Save applies the selected mode."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Mode"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_mode
                    options: [
                      { value: "local", label: "Local" },
                      { value: "cloud", label: "Cloud" }
                    ]
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) {
                      root.s_mode = v
                      root.connectionStatus = ""
                    }
                  }
                }

                // Local mode: the server to talk to.
                Column {
                  visible: root.s_mode !== "cloud"
                  width: parent.width
                  spacing: Style.spacing.labelGap
                  Text {
                    text: "Ollama host"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                  }
                  TextField {
                    id: hostField
                    width: parent.width
                    text: root.s_host
                    placeholderText: "http://localhost:11434"
                    onTextEdited: root.s_host = text
                    onAccepted: {
                      if (root.saveConnection()) root.testConnection()
                    }
                  }
                }

                // Cloud mode: the API key from ollama.com/settings/keys.
                Column {
                  visible: root.s_mode === "cloud"
                  width: parent.width
                  spacing: Style.spacing.labelGap
                  Text {
                    text: "Ollama Cloud API key"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                  }
                  TextField {
                    id: apiKeyField
                    width: parent.width
                    text: root.s_api_key
                    placeholderText: "ollama.com/settings/keys"
                    password: true
                    onTextEdited: root.s_api_key = text
                    onAccepted: {
                      if (root.saveConnection()) root.testConnection()
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight

                  Button {
                    id: saveConnectionButton
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Save"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: {
                      if (!root.saveConnection()) return
                      if (root.s_mode === "cloud" && String(root.s_api_key).trim() !== "") root.saveApiKey()
                      root.testConnection()
                    }
                  }

                  Button {
                    id: removeKeyButton
                    visible: root.s_mode === "cloud"
                    anchors.left: saveConnectionButton.right
                    anchors.leftMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Remove stored key"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.removeApiKey()
                  }

                  Text {
                    visible: root.apiKeyFlashText !== ""
                    text: root.apiKeyFlashText
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.left: removeKeyButton.right
                    anchors.leftMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Button {
                    id: testConnectionButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.connTesting ? "Testing..." : "Test connection"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    enabled: !root.connTesting
                    onClicked: root.testConnection()
                  }
                }

                PanelSeparator {
                  width: parent.width
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.connectionStatus
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Local mode uses your own Ollama server at the host above. Cloud mode talks directly to ollama.com and works without a local install; usage follows your ollama.com plan (free plans have limits). Local-only options such as num_ctx, ollama signin and running-model control do not apply in cloud mode. Your API key is stored in " + root.keyFile + " with owner-only permissions (600)."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Rectangle {
              id: connectionWarning
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.foreground, root.accent)
              implicitHeight: connectionWarningText.implicitHeight + Style.spacing.xl * 2

              Text {
                id: connectionWarningText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.xl
                anchors.rightMargin: Style.spacing.xl
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                text: "Local and Cloud use different models. After switching mode, pick and save the correct model in the Settings tab."
                color: Style.selectedStateColor(root.foreground, root.accent)
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }
          }

          // ---- About tab ----
          Item {
            id: aboutContent
            anchors.fill: parent
            visible: root.currentTab === "about"

            Flickable {
              id: aboutScroll
              anchors.fill: parent
              contentHeight: aboutColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: aboutColumn
                width: aboutScroll.width
                spacing: Style.spacing.panelGap

                Text {
                  text: (root.manifest && root.manifest.name) || "Ask Ollama"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  text: "Version " + ((root.manifest && root.manifest.version) || "?")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: "Released: " + ((root.manifest && root.manifest.releaseDate) || "?")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: 'GitHub: <a href="https://github.com/henksys/omarchy-ask-ollama" style="text-decoration:none">https://github.com/henksys/omarchy-ask-ollama</a>'
                  textFormat: Text.StyledText
                  color: root.foreground
                  linkColor: Style.selectedStateColor(root.foreground, root.accent)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                }

                PanelSeparator {
                  width: parent.width
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: (root.manifest && root.manifest.description) || "Chat with Ollama — local models or ollama.com cloud — from the desktop"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: "Features"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Column {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Threaded conversation: each question paired with its answer"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Selectable messages: drag to select part or all of a message to copy it to the clipboard; double-click selects the whole message"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Optional conversation history for follow-up context"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Live model list from Ollama (Settings - Refresh), local and cloud entries"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Local or cloud mode (Connection tab): your own Ollama server, or ollama.com with an API key and no local install"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }

                PanelSeparator {
                  width: parent.width
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "All open source scripting, no use of binaries: the whole UI, the logic, and even the API call (it runs curl and parses JSON — all visible in Ask.qml/AskModel.js). There are no compiled artifacts, no obfuscation."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Licensed under the MIT License."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
              }
            }
          }
        }
      }
    }
  }
  }

  // ---- Components ----

  Component {
    id: threadDelegate

    Item {
      id: wrap
      required property var model
      width: chatList.width
      height: contentColumn.height + Style.spacing.xxl

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.xs

        Rectangle {
          id: questionBubble
          anchors.right: parent.right
          width: Math.min(wrap.width * 0.86, questionText.implicitWidth + Style.spacing.xxl * 2)
          height: questionText.height + Style.spacing.xl * 2
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.foreground, root.accent)

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: questionText.selectAll()
          }

          TextEdit {
            id: questionText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.xxl
            anchors.topMargin: Style.spacing.xl
            text: model.question
            color: Style.selectedStateColor(root.foreground, root.accent)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            readOnly: true
            selectByMouse: true
            activeFocusOnTab: false
            cursorVisible: false
            selectionColor: Style.selectionFillFor(root.foreground, root.accent)
            selectedTextColor: Style.selectedStateColor(root.foreground, root.accent)
            onSelectedTextChanged: {
              root._pendingSelection = selectedText
              if (selectedText !== "") copyTimer.restart()
              else copyTimer.stop()
            }
          }
        }

        Rectangle {
          id: answerBubble
          anchors.left: parent.left
          visible: model.answer !== ""
          width: Math.min(wrap.width * 0.86, answerText.implicitWidth + Style.spacing.xxl * 2)
          height: answerText.height + Style.spacing.xl * 2
          radius: Style.cornerRadius
          color: model.isError ? Util.alpha(Color.urgent, 0.22) : Style.hoverFillFor(root.foreground, root.accent)

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: answerText.selectAll()
          }

          TextEdit {
            id: answerText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.xxl
            anchors.topMargin: Style.spacing.xl
            text: model.answer
            color: model.isError ? Color.urgent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            readOnly: true
            selectByMouse: true
            activeFocusOnTab: false
            cursorVisible: false
            selectionColor: Style.selectionFillFor(root.foreground, root.accent)
            selectedTextColor: model.isError ? Color.urgent : root.foreground
            onSelectedTextChanged: {
              root._pendingSelection = selectedText
              if (selectedText !== "") copyTimer.restart()
              else copyTimer.stop()
            }
          }
        }
      }
    }
  }
}
