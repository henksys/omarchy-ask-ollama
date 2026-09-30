# Overview

### Ask Ollama

**Current Version:** 1.0.0

Chat with Ollama from your desktop — ask a question and get an answer in a pane
that appears in the middle of your screen, with the conversation shown as a
scrollable thread. Works with local models, and with cloud models once you are
signed in to ollama.com (`ollama signin`). This plugin is mostly useful for
when you suddenly have a question and want a quick answer.

Note: To make use of this plugin you need Ollama installed and running. The
Connections tab defaults to `http://localhost:11434`.

Some features:

- Very fast threaded conversation: each question paired with its answer
- Selectable messages: drag with left-mouse button to select part or all of a message to copy it to the clipboard; double-click selects the whole message
- Optional conversation history for follow-up context
- When history is enabled in the settings, You can clear history in the chat panel at anytime to start with fresh context.
- Live model list from Ollama (Settings - Refresh), including cloud entries marked `(cloud)`. Set the model you prefer.
- Options like role, Temperature, Thinking (for models that support it) and num_ctx can be set to your liking
- Configurable Ollama host in the Connection tab (local or remote)

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
- **Thinking** (disabled automatically for models whose capabilities lack `thinking`)
- **Context length (num_ctx)**, blank keeps the model default
- **Temperature** and **Top P**
- **Output format** (text or json_object)
- **Save conversation history** (on/off)
- **Screensize** (small / medium / full)
- **Restore defaults** resets the config and clears history

Changes are saved to `~/.config/ask-ollama/config` and apply immediately.

### Connection tab

Shows and edits the Ollama host (default `http://localhost:11434`). **Test
connection** reports the daemon version and whether you are signed in to
ollama.com. Cloud models require a one-time `ollama signin`; after that they
appear in the model list marked `(cloud)` and run through the same local
server.

## Configuration

| File | Purpose |
|------|---------|
| `~/.config/ask-ollama/config` | Settings (JSON, editable in the panel or by hand) |
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
- Ollama installed and running (local models; cloud models need `ollama signin`)
- curl (used for the Ollama API calls)
- python3 (descriptor-based safe file reads)

## Fully open code - NO binaries

- This public repo contains exactly five files: Ask.qml, AskModel.js, manifest.json, README.md, LICENSE — all plain text/source.
- License: MIT (LICENSE), which is permissive — anyone can view, use, modify, and redistribute it.
- Everything is inspectable: the whole UI, the logic, and even the API call (it runs curl and parses JSON — all visible in Ask.qml/AskModel.js). There are no compiled artifacts, no obfuscation, nothing hidden.

## Security

- No API keys are stored in this version. Requests go to the Ollama host you
  configure; `http://` is accepted only for loopback hosts, remote hosts must
  use `https://`. Requests never follow redirects.
- Request bodies are sent to curl over stdin, never as command-line arguments.
- Requests enforce strict limits: connect timeout 10s, transfer timeout 300s
  (chat) / 30s (models), and a hard response-size cap (10 MiB chat / 1 MiB
  models). Timed-out, oversized, and truncated responses are rejected.
- Private files (`~/.config/ask-ollama/` and `~/.local/share/ask-ollama/`) are
  kept at 0700 and their config/history files at 0600. Reads use a
  descriptor-based check (O_NOFOLLOW, regular-file only, byte-capped); writes
  use unpredictable same-directory temp files with an atomic rename, so
  nothing follows a symlink and no check-then-open race exists.

## License

MIT
