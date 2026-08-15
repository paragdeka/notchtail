# Notch Status

A tiny native macOS status island for Codex, Pi **and opencode**. Pac-Man eats its way across the notch while a local turn is running, turns green when complete, orange-red when stopped, and expands on hover or click to show prompt-first sessions with status, latest response, model, context/token usage, source, project, and grouped subagents.

The expanded footer keeps total status, remaining account-wide limits, and the next reset time visible even when no session is active. For Pi and opencode sessions the footer shows aggregate session tokens and cost, since their session stores carry usage/cost but no account rate-limit data.

It watches Codex's and Pi's shared local session events and reconciles them once a second, so the Codex desktop app, CLI, VS Code extension, and Pi can run at the same time without separate integrations. opencode support reads its local SQLite session store (`~/.local/share/opencode/opencode.db`, or `$XDG_DATA_HOME/opencode/opencode.db`) once a second over a read-only connection. It uses no network access and animates only while a turn is active.

Pi sessions get a cyan source marker (Codex: blue = VS Code extension, green = CLI, purple = desktop) and their own pet: a pixelated π sprite replaces Pac-Man in pi rows and status icons, bobbing while a pi turn runs, hopping across the notch eating dots when only pi sessions are active, and chasing behind Pac-Man when both agents run at once. Pi turn state maps 1:1 onto Codex: a user message starts a turn, an assistant reply ending in `toolUse` keeps it running, `stop`/`length` completes it (green + notification), and `aborted`/`error` stops it (orange). Pi model labels show model/thinking level (e.g. `glm-5.3/high`), context percentage uses the context window from `~/.pi/agent/models-store.json`, and session names set with `/name` act as titles.

opencode sessions get a silver source marker and their own pet: a pixelated opencode logo (square frame with the cursor block riding low) that bobs while a turn runs and chases behind the other agents when several run at once. Turn state maps onto Codex: a fresh user message or an assistant reply still streaming marks running, a completed reply marks ready (green + notification), and an aborted reply marks stopped (orange). Model labels show model/reasoning variant (e.g. `glm-5.3/high`), rows show the session's own title, and subagent sessions (`@explore` and friends) group under their parent.

Completed and stopped threads stay visible for 15 minutes, or until the same thread starts another turn. A completion stays green until you return to its Codex, editor, or terminal surface. A silent running turn falls back to stopped after six hours for Codex and thirty minutes for Pi and opencode (both stream turns as discrete events, so long silences mean the agent is gone).

## Build and run

Requires macOS 13+ and Xcode Command Line Tools.

```sh
make test
make app
open dist/NotchStatus.app
```

The app has no Dock icon. Click the island or outside it to close; right-click it to quit.

## Keep it running

Move `dist/NotchStatus.app` to `/Applications`, then add it in **System Settings → General → Login Items**. This uses macOS's native login-item support instead of a background helper.

By default it reads `~/.codex/sessions`, `~/.pi/agent/sessions`, and `~/.local/share/opencode/opencode.db`. Shell-defined `CODEX_HOME`, `PI_CODING_AGENT_DIR`, and `XDG_DATA_HOME` are also respected when the app is started from that shell.
