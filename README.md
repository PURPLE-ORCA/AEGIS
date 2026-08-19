# Aegis

Aegis is a personal macOS notch app for monitoring AI coding agents. It receives agent hook events through a small bridge, shows live session state in a borderless notch panel, surfaces supported permission requests, and jumps back to the originating terminal or app.

Codex Desktop and Hermes Desktop are monitored directly from their local session stores. Their desktop integrations do not require launching either provider from a terminal.

Mysa is the optional Aegis ambient companion. Its transparent desktop panel reflects only useful local state—idle, observing, working, attention, success, and failure—with no account, economy, streak, or reward loop. Animation stops while hidden, occluded, idle, in Low Power Mode, or when Reduce Motion is enabled.

Supported agents:

- Codex
- Hermes
- OpenCode
- AntiGravity (`agy`)

## Requirements

- macOS 14 or later
- Swift 5.9 or later
- At least one supported agent installed and configured

## Build

```bash
swift build
swift build -c release
```

Build a runnable macOS app bundle:

```bash
./scripts/build-app.sh 0.1.0
```

The app is written to `build/Aegis.app`.

## Run

Run the SwiftPM debug executable:

```bash
.build/debug/Aegis
```

Or launch the app bundle:

```bash
open build/Aegis.app
```

> First launch installs Aegis hook entries into detected agent configurations under `~/.codex`, `~/.hermes`, `~/.gemini`, and `~/.config/opencode`. Back up those files first if you need an external recovery point.

## Architecture

```text
Agent hooks
    -> ~/.aegis/bin/aegis-<agent>-bridge
    -> AegisBridge
    -> /tmp/aegis.sock
    -> session store
    -> SwiftUI/AppKit notch window

Codex Desktop ~/.codex/sessions/*.jsonl ─┐
Hermes Desktop ~/.hermes/state.db ───────┴─> canonical events -> session store
```

The bridge normalizes provider events into the app's canonical event set. The app preserves the existing session/process sweep, permission and question queue, terminal jumper, rate-limit polling, sound engine, theme tokens, and mascot rendering engine.

Desktop monitoring is read-only. Aegis shows prompts, working/tool state, and final responses, while permission decisions remain inside Codex Desktop or Hermes Desktop. CLI permission requests continue to use the bridge and can be answered from the notch.

Session cards are clickable. Codex Desktop cards open the exact task through Codex's thread deep link. Hermes Desktop cards activate Hermes and select the matching session tab; macOS requests Accessibility access the first time this exact-tab feature is used. If that permission is not granted, the card still brings Hermes to the foreground.

Runtime state is stored under `~/.aegis/`:

```text
~/.aegis/
├── bin/
├── cache/rl.json
├── config.json
├── debug.log
├── run/aegis.pid
└── sound-packs/
```

Useful development commands:

```bash
tail -f ~/.aegis/debug.log
echo '{"session_id":"test","hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | .build/debug/AegisBridge --source codex
```

This repository is personal and private. It is not distributed as an open-source project.
