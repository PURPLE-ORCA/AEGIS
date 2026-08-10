# CAESURA-ISLAND handoff

## Repository

Location: `/Users/purpleorca/Documents/DEV/FULLSTACK/CAESURA-ISLAND`

The repository has fresh local history with no imported upstream Git ancestry. The runnable product is an ad-hoc-signed arm64 app bundle at `build/CAESURA-ISLAND.app`.

Build and run:

```bash
cd /Users/purpleorca/Documents/DEV/FULLSTACK/CAESURA-ISLAND
swift build
swift build -c release
./scripts/build-app.sh 0.1.0
open build/CAESURA-ISLAND.app
```

Final verification passed for the debug build, release build, bundle assembly, `Info.plist` validation, and `codesign --verify --deep --strict`. The local bundle is ad-hoc signed, not Developer ID signed or notarized.

## Follow-up improvements

- Codex quota display now classifies windows from API duration, shows remaining quota, and refreshes every minute. Current verified output: `7d 42% left 5d3h`.
- Notch hover is instant on the standalone built-in display. With multiple active displays it uses a 350ms intent delay so fast crossings cancel. Click still opens immediately, and Settings includes an `Expand on hover` toggle for click-only mode.
- Default game-style waveforms were replaced by restrained sine-partial notification tones. Session start/end and tool-use chatter default to Off.
- New purple-black `Caesura` appearance is selected by default through a one-time preference migration.
- Command-comma now opens the real Settings window instead of the empty SwiftUI settings scene.
- Follow-up GUI evidence: [`docs/test-evidence/17-followup-results.txt`](docs/test-evidence/17-followup-results.txt).

## Scope completed

- Removed 13 of the 17 upstream agent providers and retained exactly Codex, Hermes, OpenCode, and AntiGravity.
- Deleted 56 tracked upstream files across provider implementations, provider artwork, old documentation/site assets, credits, licensing, funding, updater, and demo tooling.
- Removed all 9 requested upstream-identity search targets from the working tree, together with upstream repository URLs, update feed, screenshots, and logo artwork.
- Renamed the app, products, targets, bundle identity, socket, config domain, bridge, launchers, defaults domain, hook marker, and on-disk state to CAESURA-ISLAND / CaesuraIsland.
- Preserved the bridge, socket protocol, canonical events, in-memory session store and process sweep, terminal jumper, permission/question queue, rate-limit polling, sound engine, theme tokens, and mascot engine.
- Rewrote the README, engineering spec, and changelog in English.

`AIProvider.all` is the source of truth and contains exactly:

```swift
[.codex, .hermes, .opencode, .antigravity]
```

## Computer-use test results

| Checklist item | Result | Evidence |
| --- | --- | --- |
| 1. Launch, top-center borderless notch, no focus steal | Pass | [`docs/test-evidence/01-launch-not-focused.png`](docs/test-evidence/01-launch-not-focused.png), [`docs/test-evidence/12-final-build-launch.png`](docs/test-evidence/12-final-build-launch.png) |
| 2. First-launch installers and foreign-config preservation | Pass | [`docs/test-evidence/02-installers.txt`](docs/test-evidence/02-installers.txt) |
| 3. Hermes live working → finished | Pass | [`docs/test-evidence/04-hermes-working.png`](docs/test-evidence/04-hermes-working.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 3. OpenCode live working → finished | Pass | [`docs/test-evidence/06-opencode-working.png`](docs/test-evidence/06-opencode-working.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 3. Codex live working → finished | Partial / live UI untested | The real command completed, but installed Codex CLI 0.135.0 did not emit lifecycle hooks. Direct launcher → bridge → socket delivery passed. See [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt). |
| 3. AntiGravity live working → finished | Partial / live UI untested | The real `agy --print` command completed, but the headless client did not emit its configured hooks. See [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt). |
| 4. Permission Allow and Deny | Pass | [`docs/test-evidence/08-opencode-permission.png`](docs/test-evidence/08-opencode-permission.png), [`docs/test-evidence/09-opencode-deny.png`](docs/test-evidence/09-opencode-deny.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 5. Terminal jump | Untested | Computer Use refused access to Ghostty for safety reasons, so the destination tab could not be driven or observed. |
| 6. Finish sound and macOS notification | Partial / untested | Completion events reached SoundEngine without error, but audible output cannot be verified through Computer Use. The preserved upstream engine has no macOS user-notification implementation; its completion notification is the notch card. |
| 7. Quit and clean relaunch | Pass | [`docs/test-evidence/10-clean-relaunch.png`](docs/test-evidence/10-clean-relaunch.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 7. Session recovery after relaunch | Unsupported / untested | The preserved SessionStore is in-memory and has no disk serialization, so cross-process session recovery cannot be claimed. |

No crash, hang, or focus steal occurred during the completed GUI tests.

## Real agent configuration changes

Backups were created before first launch:

- `~/.codex/config.toml.bak-caesura`
- `~/.hermes/config.yaml.bak-caesura`
- `~/.config/opencode/opencode.json.bak-caesura`

The corresponding Codex hooks, Gemini/AntiGravity hooks, and OpenCode JSONC files did not exist before launch, so there was no original file to copy. CAESURA-marked entries now exist in the four real agent configurations, and the four launchers are installed under `~/.caesura-island/bin`. Details and hashes are in [`docs/test-evidence/02-installers.txt`](docs/test-evidence/02-installers.txt).

## Deliberate leftovers

- `CLAUDE.md` remains as the repository's engineering-spec filename; its content is rewritten for CAESURA-ISLAND and contains no Claude provider integration.
- `~/.gemini/config/hooks.json` and `.gemini/antigravity` remain because they are AntiGravity's required configuration and detection paths, not a Gemini provider integration.
- `cursor` remains only in TerminalJumper's supported editor/terminal targeting logic; no Cursor agent provider remains.
- `https://github.com/simibac/ConfettiSwiftUI.git` remains as the sole GitHub package dependency and is unrelated to upstream identity.
- The first fresh-history commit subject names the imported upstream repository because Phase 0 explicitly required that subject; no upstream commits or ancestry remain.
- The upstream checkout contained no `ios/CodeIslandCompanion` or `apple-companion` tree, so there was no companion source available to preserve or rename.
