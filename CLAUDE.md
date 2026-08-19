# Aegis Engineering Guide

Aegis is a native macOS notch app for monitoring four AI coding agents: Codex, Hermes, OpenCode, and AntiGravity. It is written in Swift 5.9+ with SwiftUI and AppKit, targets macOS 14+, and builds with Swift Package Manager.

## Architecture

```text
agent hook
  -> ~/.aegis/bin/aegis-<agent>-bridge
  -> AegisBridge --source <agent>
  -> /tmp/aegis.sock
  -> SocketServer
  -> SessionStore
  -> NotchWindowController / SwiftUI views
```

The app target is `Aegis`. The bridge target is `AegisBridge`. On launch, `CodexInstaller` and the descriptor-driven `ProviderInstaller` write provider launchers under `~/.aegis/bin` and merge managed hook entries into detected configurations. Each launcher resolves the bridge embedded in the current app bundle before trying installed-app and development paths.

Do not launch the app in an environment where provider configs must remain untouched. First launch may install hooks.

## Build and app bundle

```bash
swift build
swift build -c release
./scripts/build-app.sh
open build/Aegis.app
```

`scripts/build-app.sh` compiles the release products and assembles a runnable app bundle at `build/Aegis.app`.

## Provider source of truth

`AIProvider.all` contains exactly:

- `codex`
- `hermes`
- `opencode`
- `antigravity`

Each provider owns a display name, accent color, mascot palette, mascot shape, and supported permission actions. CLI icons live in `Resources/cli-icons/<id>.png`; rendered documentation mascots live in `docs/mascots/<id>.png`.

## Bridge protocol

Each hook invokes `AegisBridge`, which reads JSON from stdin, stamps the provider source, captures its parent PID and terminal environment, normalizes the event, and sends one newline-delimited JSON message over the Unix socket.

The canonical events are:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `PermissionRequest`
- `Stop`
- `Notification`
- `SubagentStart`
- `SubagentStop`
- `PreCompact`

`SessionStore` rejects non-canonical events. Preserve this guard: a foreign hook sharing the socket must not create or mutate a session.

Important bridge fields include `session_id`, `hook_event`, `source`, `cwd`, `tool_name`, `tool_input`, `user_message`, `assistant_message`, `agent_pid`, `_env`, and the optional file/diff fields used by permission cards.

## Provider normalization

### Codex

Codex uses native `hooks.json` events plus `[features].hooks = true` in `~/.codex/config.toml`. The installer merges managed commands without replacing foreign hooks.

Codex permission responses use the canonical allow/deny response. `Allow All` and `Bypass` persist a `prefix_rule` through `CodexPermissionRules` when the request can be represented as a shell prefix, then allow the current request. Do not send unsupported permission-update payloads to Codex.

Codex `request_user_input` arrives through `PreToolUse`. The notch mirrors the question, but the hook cannot substitute an answer. A response jumps to Codex or its terminal; `PostToolUse` dismisses the mirrored question.

The Codex app-server client enriches sessions with thread names and lifecycle events. The process sweep remains the fallback for sessions whose hook stream omits a terminal event.

### Hermes

Hermes hooks are merged into `~/.hermes/config.yaml`. Preserve existing YAML content and foreign hooks. Hermes event names are normalized into the canonical set.

The bridge strips terminal control sequences, translates consent events into permission requests, and reshapes `clarify` payloads into the canonical question structure. Hermes question answers remain in Hermes; the notch jumps to the originating terminal or app.

Strict approval is opt-in and mirrored to `~/.aegis/config.json` so the bridge can read it without attaching to the app process.

### OpenCode

The installer writes the Aegis plugin under `~/.config/opencode/plugins/` and registers it in `~/.config/opencode/opencode.json` without discarding unrelated plugins.

The plugin translates OpenCode lifecycle events, `permission.asked`, and question events into canonical bridge messages. It applies the bridge response through OpenCode's local API. Preserve the plugin's session, permission, and question identifiers.

### AntiGravity

The installer merges a named `aegis` hook group into `~/.gemini/config/hooks.json`. It only installs when AntiGravity is detected under `~/.gemini/antigravity`. AntiGravity must be restarted after hook changes because its daemon caches configuration.

AntiGravity emits limited hook payloads. The bridge reads its `transcript.jsonl` to recover the latest user request and model planner response. Its `PreToolUse` event can become a blocking permission request when strict approval is enabled, and the canonical decision is translated back into AntiGravity's native response.

## Installer guarantees

Managed entries contain the marker `# aegis-managed` or the equivalent structured `aegis` key. Installer changes must be additive:

- Preserve foreign hooks and unrelated configuration.
- Create a backup before rewriting an existing config.
- Use atomic replacement where implemented.
- Keep launcher names under `~/.aegis/bin`.
- Keep socket and config paths centralized; do not introduce legacy path fallbacks.

The retained installer formats are `hermesYAML`, `opencodePlugin`, and `antigravityJSON`, plus the dedicated Codex installer.

## Session lifecycle

`SessionStore` is the session source of truth. It maintains active state, current tool, pending permissions/questions, terminal metadata, last user/assistant text, model, and provider identity.

The process sweep runs every five seconds. It validates the captured PID and process start time before marking a vanished agent complete, preventing false matches after PID reuse. Session persistence and recovery must remain provider-neutral.

Pending decisions are queued oldest-first. The notch must not switch to a second prompt while the user is acting on the first. Terminal-side completion dismisses the matching prompt and advances the queue.

## Terminal jump

`TerminalJumper` uses captured terminal metadata to return to the originating tab, pane, or app. Keep the specific adapters for Terminal, iTerm2, tmux, Ghostty, Kitty, WezTerm, VS Code-family terminals, JetBrains IDEs, and Codex.app. Terminal support is independent of the four agent integrations.

## UI engines

The notch is an AppKit panel hosting SwiftUI. It is borderless, non-activating, top-centered, and adapts to notch and non-notch displays. State consists of collapsed, expanded, finished, permission, and question views.

The following are retained engines, not provider-specific code:

- theme tokens and themed surface modifiers
- pixel mascot renderer and animation timing
- sound synthesis and sound-pack loading
- rate-limit display and polling
- notification delivery
- permission and question queue
- terminal jumping

Themes may change chrome but must preserve semantic status and action colors. Mascot palettes remain provider-owned.

## Logging and state

Runtime state is under `~/.aegis`:

- `cache/rl.json`
- `debug.log`
- `sound-packs/`
- `config.json`
- `bin/`

The app bundle identifier and UserDefaults domain are `dev.aegis.app`. The sole socket path is `/tmp/aegis.sock`.

## Change discipline

Keep diffs limited to the requested behavior. Do not replace the bridge, installer, session, theme, mascot, sound, or terminal engines with new abstractions. After changes, run `swift build`; for release-affecting changes also run `swift build -c release` and `./scripts/build-app.sh`.
