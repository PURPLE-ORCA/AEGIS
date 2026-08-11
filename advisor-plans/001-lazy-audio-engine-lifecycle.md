# 001 — Lazy audio engine lifecycle

Status: IMPLEMENTED (`a07d769`, cleanup `5a8bdaa`)
Priority: P0 energy efficiency
Baseline commit: `c9450ce`

## Why this matters

CAESURA-ISLAND is an all-day background utility. `AppDelegate` constructs `SoundEngine` eagerly, and `SoundEngine.init()` immediately starts an `AVAudioEngine`. Disabling sound only flips a Boolean; it does not stop or release the engine. Runtime sampling confirmed persistent CoreAudio I/O and parameter-refresh threads while no sound was playing.

Current state:

```swift
init() {
    setupAudioEngine()
    loadSounds()
}

func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
}
```

See `Sources/CaesuraIsland/Sound/SoundEngine.swift:25-28`, `:50-52`, and `:80-103`.

## Required outcome

The audio graph must not exist while muted and must stop after an idle grace period when enabled. Playback and Settings previews must lazily start it, reuse it during a short burst, and tear it down safely afterward.

## Scope

In scope:

- `Sources/CaesuraIsland/Sound/SoundEngine.swift`
- `Sources/CaesuraIsland/App/AppDelegate.swift` only if lifecycle wiring is required
- New focused tests under `Tests/CaesuraIslandTests/`

Out of scope:

- Changing sound synthesis, event-to-sound mappings, volume semantics, or sound files
- Replacing the retained sound engine with a third-party library
- Editing Settings UI
- The four pre-existing dirty finished-card files

## Implementation steps

1. Add a small, testable lifecycle policy that represents `stopped`, `running`, and `idle teardown pending`. Keep `SoundEngine` as the retained public engine; do not create a parallel audio subsystem.
2. Remove `setupAudioEngine()` from `init()`. Loading the small default sound buffers may remain eager, but creating/starting `AVAudioEngine` and `AVAudioPlayerNode` must be lazy.
3. Add `ensureAudioEngineRunning()` and call it only from `playBuffer`. It must create, attach, connect, start, and apply current volume exactly once per running lifetime.
4. After scheduling a buffer, arm a two-second idle teardown. A new play or preview cancels and rearms that teardown. Use one queue/actor consistently; do not stop an engine concurrently from an AVAudio completion callback.
5. On teardown, stop the player, stop/reset the engine, detach or discard the player, and nil both stored objects. The next sound must cold-start cleanly.
6. `setEnabled(false)` must cancel pending work and tear down immediately. `setEnabled(true)` must not start audio until playback. Preview buttons intentionally bypass the global enabled flag and therefore may lazily start audio.
7. Handle engine start failure without leaving partially initialized objects that block a future retry.

After steps 1–3, run `swift test`. After steps 4–7, run the full shared verification protocol from `advisor-plans/README.md`.

## Tests

Add `SoundEngineLifecycleTests.swift`. Follow the repository pattern of extracting deterministic policy from framework-heavy code, as `AutoCollapsePolicyTests.swift` does.

Cover:

- initialization remains stopped;
- ordinary playback requests start once;
- multiple sounds inside the grace period reuse one running generation;
- an idle deadline requests teardown;
- disabling tears down immediately and cancels pending teardown;
- enabling alone does not start audio;
- preview while disabled still starts a temporary engine;
- a failed start can be retried.

Do not make unit tests open the real audio device. Inject a narrow engine-driver seam or test the lifecycle reducer separately. Keep AVFoundation integration in `SoundEngine`.

## Before/after metrics

Before editing, record a five-second idle `sample` and the 30-sample baseline. After editing:

1. Launch the release app with sound enabled and wait five seconds after any startup sound.
2. Sample for five seconds. `com.apple.audio.IOThread.client` and `AUScheduledParameterRefresher` must not remain attributable to CAESURA-ISLAND.
3. Play a Settings preview, verify audio starts, wait three seconds, and sample again to verify teardown.
4. Repeat `./scripts/measure-performance.sh 30` with the same session workload.

## Done criteria

- All lifecycle tests and the shared verification gates pass.
- No persistent audio graph exists five seconds after the last sound.
- Muting stops the engine immediately; unmuting does not start it.
- Preview and normal event playback still work after at least two stop/restart cycles.
- The handoff includes raw before/after CPU, RSS, descriptor, and sample evidence.

## Escape hatches

- If stopping the engine causes an audible truncation because completion timing is unavailable, STOP and report the observed callback behavior; do not increase the grace period indefinitely.
- If AVAudioEngine cannot restart reliably after output-device changes, STOP and propose a device-change recovery test before shipping.
- If tests require real audio hardware, isolate policy testing instead of weakening CI.

## Maintenance note

Any future sound event or preview path must go through `playBuffer`; direct player-node access would bypass the idle lifecycle and reintroduce permanent audio wakeups.
