<p align="center">
  <img src="docs/images/icon.webp" alt="notchtail app icon" width="128">
</p>

<h1 align="center">notchtail</h1>

<p align="center">
  <b>Your coding agents, live in the MacBook notch.</b><br>
  A native macOS app that shows when Codex, Claude Code, Pi, and opencode<br>
  are running, waiting on you, done, or stopped.
</p>

<p align="center">
  <a href="https://github.com/paragdeka/notchtail/releases/latest"><b>Download the latest release</b></a> · Requires macOS 13 or later
</p>

<p align="center">
  <img src="docs/images/hero.webp" alt="notchtail expanded under a MacBook notch: a Codex thread with three subagents, one waiting for approval to run pnpm add bullmq, followed by Claude Code, opencode, and Pi sessions and the remaining Codex and Claude limits" width="880">
</p>

## At a glance

Collapsed, the island shows how many sessions are running, and a pet for each busy agent trots out from under the notch. When an agent finishes, its pet turns green and hops away.

<p align="center">
  <img src="docs/images/pets.webp" alt="Animation of the collapsed island counting three running sessions while Codex, Pi, and Claude pets trot out from under the notch. Pi and Claude finish and hop away in green, then Codex finishes and the island shows a green check." width="880">
</p>

<p align="center">
  <img src="docs/images/states.webp" alt="The collapsed island's four states: a running count with agent pets, Claude asking with a pink question mark, Codex done with a green check, and opencode stopped with an orange cross" width="880">
</p>

## What it shows

- **Status:** running, waiting for input, done, or stopped, including provider failures.
- **Subagents:** grouped under their parent. Work stays active until the last subagent finishes.
- **Session details:** latest response, model, project, and token or context usage where available.
- **Account limits:** remaining Codex and Claude usage, with reset times.
- **Alerts:** a notification when work finishes or an agent needs your input.

Hover or click the island to see session details and expand subagent groups.

| Agent | Works with | Account limits |
| --- | --- | --- |
| Codex | Desktop app, CLI, VS Code extension | 5-hour and weekly |
| Claude Code | CLI, VS Code extension, local Desktop Code sessions | 5-hour and weekly |
| Pi | CLI | — |
| opencode | v1 and v2 sessions | — |

## Install

1. Download `notchtail-<version>.dmg` from the [latest release](https://github.com/paragdeka/notchtail/releases/latest).
2. Open it and drag **notchtail** to **Applications**.
3. Open notchtail and allow notifications when asked.

The app isn't notarized by Apple, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

```sh
xattr -dr com.apple.quarantine /Applications/notchtail.app
```

## Controls

- **Open:** hover or click. **Close:** click the island or outside it.
- **Start at login:** right-click → **Launch at Login**.
- **Manage alerts:** right-click → **Notification Settings…** A yellow crossed-out bell means notifications are off.
- **Quit:** right-click → **Quit notchtail**. The app has no Dock icon.

Answer questions and approve commands in the agent's own app or terminal.

## Good to know

- **Read-only monitoring.** Session status comes from local files and databases. Requests that an agent doesn't save locally may not appear.
- **Claude coverage.** Chat, Cowork, and remote-only Desktop sessions are excluded.
- **Account access.** Limits use authenticated requests to OpenAI and Anthropic with your existing logins. Credentials are never logged or changed.
- **Keychain access.** If macOS asks, choose **Always Allow** to let Claude limits refresh in the background. The approval applies to macOS's `security` tool, so it survives app updates.

## Build from source

**Requires macOS 13+ and Xcode Command Line Tools.**

```sh
make test
make app
open dist/notchtail.app
```

Allow notifications when prompted. For daily use, move `dist/notchtail.app` to `/Applications` and open it there.

<details>
<summary>Session folders and timeouts</summary>

Default sources:

- Codex: `~/.codex/sessions`
- Claude: `~/.claude/projects`
- Pi: `~/.pi/agent/sessions`
- opencode: `~/.local/share/opencode/opencode.db`, including channel-specific databases.

Custom folders use `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, or `XDG_DATA_HOME` when launched from that shell.

Completed and stopped sessions stay visible for 15 minutes. Silent turns may be marked stopped after 6 hours for Codex or 30 minutes for the other agents.

</details>
