# Notch Status

A tiny native macOS status island for Codex. Pac-Man eats its way across the notch while a local turn is running, turns green when complete, orange-red when stopped, and expands on hover to show each thread's latest response, color-coded source, and working directory.

It watches Codex's shared local session events and reconciles them once a second, so the Codex desktop app, CLI, and VS Code extension can run at the same time without separate integrations. It uses no network access and animates only while a turn is active.

Completed and stopped threads stay visible for 15 minutes, or until the same thread starts another turn.

## Build and run

Requires macOS 13+ and Xcode Command Line Tools.

```sh
make test
make app
open dist/NotchStatus.app
```

The app has no Dock icon. Right-click the island to quit.

## Keep it running

Move `dist/NotchStatus.app` to `/Applications`, then add it in **System Settings → General → Login Items**. This uses macOS's native login-item support instead of a background helper.

By default it reads `~/.codex/sessions`. A shell-defined `CODEX_HOME` is also respected when the app is started from that shell.
