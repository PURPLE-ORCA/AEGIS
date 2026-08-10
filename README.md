# CAESURA-ISLAND

CAESURA-ISLAND is a personal macOS notch app for monitoring AI coding agents. It receives agent hook events through a small bridge, shows live session state in a borderless notch panel, surfaces supported permission requests, and jumps back to the originating terminal or app.

Codex Desktop and Hermes Desktop are monitored directly from their local session stores. Their desktop integrations do not require launching either provider from a terminal.

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

The app is written to `build/CAESURA-ISLAND.app`.

## Run

Run the SwiftPM debug executable:

```bash
.build/debug/CaesuraIsland
```

Or launch the app bundle:

```bash
open build/CAESURA-ISLAND.app
```

> First launch installs CAESURA-ISLAND hook entries into detected agent configurations under `~/.codex`, `~/.hermes`, `~/.gemini`, and `~/.config/opencode`. Back up those files first if you need an external recovery point.

## Architecture

```text
Agent hooks
    -> ~/.caesura-island/bin/caesura-island-<agent>-bridge
    -> CaesuraIslandBridge
    -> /tmp/caesura-island.sock
    -> session store
    -> SwiftUI/AppKit notch window

Codex Desktop ~/.codex/sessions/*.jsonl ─┐
Hermes Desktop ~/.hermes/state.db ───────┴─> canonical events -> session store
```

The bridge normalizes provider events into the app's canonical event set. The app preserves the existing session/process sweep, permission and question queue, terminal jumper, rate-limit polling, sound engine, theme tokens, and mascot rendering engine.

Desktop monitoring is read-only. CAESURA-ISLAND shows prompts, working/tool state, and final responses, while permission decisions remain inside Codex Desktop or Hermes Desktop. CLI permission requests continue to use the bridge and can be answered from the notch.

Runtime state is stored under `~/.caesura-island/`:

```text
~/.caesura-island/
├── bin/
├── cache/rl.json
├── config.json
├── debug.log
├── run/caesura-island.pid
└── sound-packs/
```

Useful development commands:

```bash
tail -f ~/.caesura-island/debug.log
echo '{"session_id":"test","hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | .build/debug/CaesuraIslandBridge --source codex
```

This repository is personal and private. It is not distributed as an open-source project.
