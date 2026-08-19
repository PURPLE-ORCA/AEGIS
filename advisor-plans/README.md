# Performance advisor plans

These plans were written against commit `c9450ce` after a performance-only audit on 2026-08-11. They are intentionally separate from `plans/`, which tracks animation work.

The working tree already contained an uncommitted finished-card sizing change in these files when the plans were written:

- `Sources/Aegis/Notch/NotchContentView.swift`
- `Sources/Aegis/Notch/NotchViewModel.swift`
- `Sources/Aegis/Notch/Views/FinishedView.swift`
- `Tests/AegisTests/FinishedMessagePresentationTests.swift`

Executors must preserve those changes and must not stage, revert, or rewrite them unless a later user instruction explicitly widens scope.

## Recorded before baseline

The workspace app bundle was running with live sessions. The 30-sample command was:

```bash
./scripts/measure-performance.sh 30
```

| Metric | Before |
| --- | ---: |
| Average CPU | 5.09% |
| Resident memory | 49,472 KiB |
| Open descriptors | 81 |
| Codex transcript descriptors | 0 |
| Codex history | 265 files / 60 directories / 1,375,800 KiB |
| Largest Codex transcript | 163,623,814 bytes |
| Hermes database | 1,742,278,656 bytes / 113,404 messages |

The aggregate target after all six plans is at least 30% lower average CPU under the same workload, no RSS or descriptor regression, zero persistent Codex transcript descriptors, bounded transcript-tail memory independent of total file size, and no desktop-session recovery regression.

## Execution order

| Order | Plan | Status | Dependency |
| --- | --- | --- | --- |
| 1 | [001 — Lazy audio engine lifecycle](001-lazy-audio-engine-lifecycle.md) | IMPLEMENTED | `a07d769`, `5a8bdaa` |
| 2 | [002 — Filter and back off Hermes monitoring](002-hermes-monitor-filter-and-backoff.md) | IMPLEMENTED | `5078847`, `7e1ef98` |
| 3 | [003 — Stream transcript tails](003-stream-transcript-tails.md) | IMPLEMENTED | `4857b7a` |
| 4 | [004 — Move log formatting off the main thread](004-off-main-log-formatting.md) | IMPLEMENTED | `a701379` |
| 5 | [005 — Bound Codex reconciliation](005-bound-codex-reconciliation.md) | IMPLEMENTED | `9615721` |
| 6 | [006 — Batch session-store publications](006-batch-session-publications.md) | IMPLEMENTED | `8b6eaa8` |

Plans 1–5 are independent. Plan 6 changes the downstream cost of all watcher events, so run it last if per-plan before/after attribution matters. If only the final aggregate result matters, plan 6 may land before plans 2 and 5.

## Recorded implementation results

The release bundle was rebuilt, signed, relaunched, and measured on 2026-08-11. The final 30-sample command was:

```bash
./scripts/measure-performance.sh 30 2948
```

| Metric | Before | After | Result |
| --- | ---: | ---: | ---: |
| Average CPU | 5.09% | 2.73% | 46.4% lower |
| Resident memory (`ps` RSS) | 49,472 KiB | 84,256 KiB | 70.3% higher |
| Settled physical footprint | Not recorded | 39 MiB | Informational only |
| Open descriptors | 81 | 66 | 18.5% lower |
| Codex transcript descriptors | 0 | 0 | No regression |
| Hermes `FileEventMonitor.handle` rate | 53.7 samples/s | 8.4 samples/s | 84.4% lower |
| Codex reconciliation rate | 6.7 samples/s | 0.4 samples/s | 94.0% lower |
| Persistent CoreAudio threads | Present | 0 | Removed while idle |
| Main-thread date-formatting stacks | Present | 0 | Removed |
| 128 MiB near-end transcript read | Whole file | 64 KiB | Bounded to one chunk |
| 1,000-message publication stream | Multiple/message | 1,000 total | Exactly one/message |

The CPU and background-stack targets passed. Comparable RSS did not; the final process had a 39 MiB physical footprint but a higher `ps` RSS under a different live-session/history state, so memory is reported as a regression rather than normalized away.

During runtime verification, AppKit reproduced the pre-existing recursive hosting constraint crash. Commit `784dd69` moved `NSHostingView` below a fixed-frame AppKit container so the panel remains the sole window-size owner. The rebuilt app remained live through subsequent 30-second measurement and stack sampling.

## Shared verification and metric protocol

Every executor must run these gates from the repository root:

```bash
swift test
swift build -c release
git diff --check
./scripts/build-app.sh
codesign --verify --deep --strict build/Aegis.app
```

For runtime-affecting plans, relaunch the exact workspace bundle and verify its PID before measuring:

```bash
open -n "$PWD/build/Aegis.app"
pgrep -f "$PWD/build/Aegis.app/Contents/MacOS/Aegis"
./scripts/measure-performance.sh 30
```

Record the raw before and after output in the implementation handoff. Do not compare a debug executable with a release app bundle, different active-session counts, a different display configuration, or different sound settings. For call-stack verification, use:

```bash
pid=$(pgrep -f "$PWD/build/Aegis.app/Contents/MacOS/Aegis" | head -1)
sample "$pid" 5 1
```

## Deferred performance findings

- Full Markdown replies are eagerly parsed and laid out despite the 360-point viewport cap.
- Hermes relaunch recovery aggregates lifetime message history and replays unfinished turns row by row.
- Syntax highlighting recompiles regular expressions for every pass and every diff line.
- Active-session derivation repeatedly filters and copies the full dictionary in one SwiftUI update.
- Sound-library settings repeatedly enumerate the same directory and may decode duplicate PCM buffers.

## Considered and rejected for this round

- The five-second process sweep is a documented lifecycle fallback and stays unchanged.
- The window display link is bounded to transitions, invalidated correctly, and uses `display: false`.
- Rate-limit refresh runs once per minute and had no profiling evidence of material cost.
- Finished-card height preferences have delta guards and showed no persistent feedback loop.
- Codex transcript descriptor fan-out is already fixed; the runtime baseline confirmed zero transcript descriptors.
- File-socket accept blocking is efficient under normal traffic; slow-client exhaustion is security hardening, not this performance round.
