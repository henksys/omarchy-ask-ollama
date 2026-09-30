# Overview

### Ask Ollama

**Current Version:** 1.1.0

Chat with Ollama from your desktop — ask a question and get an answer in a pane
that appears in the middle of your screen, with the conversation shown as a
scrollable thread. Works in two modes: **Local** talks to your own Ollama
server (local and cloud models signed in with `ollama signin`), **Cloud**
talks directly to ollama.com with an API key and works without a local Ollama
install. This plugin is mostly useful for when you suddenly have a question
and want a quick answer.

Note: Local mode requires Ollama installed and running (default host
`http://localhost:11434`). Cloud mode only needs an API key from
[ollama.com/settings/keys](https://ollama.com/settings/keys).

Some features:

- Very fast threaded conversation: each question paired with its answer
- Selectable messages: drag with left-mouse button to select part or all of a message to copy it to the clipboard; double-click selects the whole message
- Optional conversation history for follow-up context
- When history is enabled in the settings, You can clear history in the chat panel at anytime to start with fresh context.
- Live model list (Settings - Refresh); in Local mode cloud entries are marked `(cloud)`
- Options like role, Temperature, Thinking (for models that support it) and num_ctx (local mode) can be set to your liking
- Local or Cloud mode in the Connection tab: your own Ollama host, or ollama.com with an API key

## Install

```sh
omarchy plugin add https://github.com/henksys/omarchy-ask-ollama.git --enable
```

## Usage

To configure `SUPER + A` as your short-key to run the "Ollama Ask" panel, Add the following lines to your ~/.config/hypr/bindings.lua ( user keybindings) file:

```sh
-- Ask Ollama panel (omarchy-ask-ollama plugin)
o.bind("SUPER + A", "Ask Ollama", "omarchy-shell shell toggle io.github.henksys.ask-ollama")
```

Then press `SUPER + A` to open the panel (or summon it from any launcher):

```sh
omarchy-shell shell toggle io.github.henksys.ask-ollama
```

- Type a question and press Enter (or click Send).
- The conversation is shown as a thread: each question with its answer.
- **Select** any part of a message to copy it to the clipboard (double-click selects the whole message).
- Escape or the Close button closes the panel.
- **Clear** empties the conversation and deletes the history file.

### Settings tab

Opens from the panel header. You can change:

- **Role / system prompt**
- **Model** (fetched live from Ollama's `/api/tags`; use **Refresh** to update the list)
- **Thinking** (disabled automatically for models whose capabilities lack `thinking`; in Cloud mode capabilities are read from the public `/api/show` endpoint)
- **Context length (num_ctx)**, blank keeps the model default (Local mode only)
- **Temperature** and **Top P**
- **Output format** (text or json_object)
- **Save conversation history** (on/off)
- **Screensize** (small / medium / full)
- **Restore defaults** resets the config and clears history

Changes are saved to `~/.config/ask-ollama/config` and apply immediately.

### Connection tab

Pick the **Mode** and press **Save**:

- **Local**: use the configured Ollama host (default `http://localhost:11434`).
  **Test connection** reports the daemon version and, when signed in, the
  ollama.com account. Cloud models appear in the model list marked `(cloud)`
  after a one-time `ollama signin`.
- **Cloud**: talks directly to `https://ollama.com` and works without a local
  Ollama install. Paste an API key from
  [ollama.com/settings/keys](https://ollama.com/settings/keys) and press
  **Save** (the key is stored at `~/.config/ask-ollama/key`, owner-only 600).
  **Test connection** reports the signed-in account and plan. Model browsing
  works without a key; chat needs one.

Cloud usage follows your ollama.com plan (free plans have limits). Local-only
options such as `num_ctx`, `ollama signin` and running-model control do not
apply in Cloud mode.

## Configuration

| File | Purpose |
|------|---------|
| `~/.config/ask-ollama/config` | Settings (JSON, editable in the panel or by hand) |
| `~/.config/ask-ollama/key` | Ollama Cloud API key (owner-only 600, optional) |
| `~/.local/share/ask-ollama/history.jsonl` | Conversation history (JSONL, one message per line) |

## Remove

```sh
omarchy plugin remove io.github.henksys.ask-ollama
```

## Update

```sh
omarchy plugin update io.github.henksys.ask-ollama
```

## Requirements

- Omarchy (Hyprland + quickshell). Tested with Omarchy Quattro.
- Local mode: Ollama installed and running
- Cloud mode: an API key from ollama.com/settings/keys, no local install needed
- curl (used for the Ollama API calls)
- python3 (descriptor-based safe file reads)

## Fully open code - NO binaries

- This public repo contains exactly five files: Ask.qml, AskModel.js, manifest.json, README.md, LICENSE — all plain text/source.
- License: MIT (LICENSE), which is permissive — anyone can view, use, modify, and redistribute it.
- Everything is inspectable: the whole UI, the logic, and even the API call (it runs curl and parses JSON — all visible in Ask.qml/AskModel.js). There are no compiled artifacts, no obfuscation, nothing hidden.

## Security

- In Cloud mode the API key is stored in `~/.config/ask-ollama/key` (owner-only
  600) and handed to curl through a 0600 header file written over stdin; it is
  never passed as a command-line argument or placed in the environment. Cloud
  requests are HTTPS-only and never follow redirects. In Local mode requests go
  to the configured host; `http://` is accepted only for loopback hosts.
- Request bodies are sent to curl over stdin, never as command-line arguments.
- Requests enforce strict limits: connect timeout 10s, transfer timeout 300s
  (chat) / 30s (models) / 6s (connection test), and a hard response-size cap
  (10 MiB chat / 1 MiB models). Timed-out, oversized, and truncated responses
  are rejected.
- Private files (`~/.config/ask-ollama/` and `~/.local/share/ask-ollama/`) are
  kept at 0700 and their config/history/key files at 0600. Reads use a
  descriptor-based check (O_NOFOLLOW, regular-file only, byte-capped); writes
  use unpredictable same-directory temp files with an atomic rename, so
  nothing follows a symlink and no check-then-open race exists.

## License

MIT
