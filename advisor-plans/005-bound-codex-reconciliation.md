# 005 — Bound Codex reconciliation

Status: IMPLEMENTED (`9615721`)
Priority: P1 background filesystem energy
Baseline commit: `c9450ce`

## Why this matters

Codex monitoring correctly uses one recursive FSEvent stream, but its safety timer still walks all historical transcripts every ten seconds. The audit machine has 265 JSONL files totaling about 1.31GiB. Each full pass rediscovers the tree, canonicalizes paths, checks existence, reads metadata, and grows with lifetime history.

Current policy in `CodexDesktopSessionWatcher.swift:103-135`:

```swift
self.reconciliationTick += 1
self.reconcileTranscripts(includeAll: self.reconciliationTick % 10 == 0)
```

`includeAll` seeds every known offset and recursively enumerates the root at `:123-147`.

## Required outcome

Active transcripts retain the one-second completion safety bound. Newly created/recent transcripts receive a frequent bounded recovery scan. Full historical discovery becomes a rare last-resort audit rather than a ten-second operation.

## Scope

In scope:

- `Sources/CaesuraIsland/Codex/CodexDesktopSessionWatcher.swift`
- `Tests/CaesuraIslandTests/CodexDesktopSessionWatcherTests.swift`
- A small internal reconciliation policy/counter type if needed

Out of scope:

- Replacing FSEvents
- Removing reconciliation or weakening active-turn completion recovery
- Parsing new Codex event formats
- Changing SessionStore lifecycle semantics
- Reintroducing per-transcript descriptors
- The dirty finished-card files

## Implementation steps

1. Replace the Boolean `includeAll` decision with explicit reconciliation scopes: `active`, `recentDiscovery`, and `fullAudit`.
2. Keep the timer at one second with 150ms leeway only while at least one transcript state is active or has tools in flight. When none are active, the timer may use a slower deadline; avoid a permanent 1Hz wakeup solely to increment a counter.
3. `active` scope must stat only paths whose state is active or has unresolved tools. Preserve the current one-second completion fallback.
4. `recentDiscovery` must run every 10 seconds and enumerate only the newest two existing date-leaf directories beneath the Codex `YYYY/MM/DD` layout. Determine them from directory names present under the injected root; do not assume the system's current timezone exactly matches Codex. Include all already-known paths modified recently if needed for reused older threads.
5. `fullAudit` may recursively enumerate the entire tree no more than once every five minutes. It remains the recovery path for missed root/directory creation events.
6. FSEvent processing remains immediate and primary. A file discovered by an event must be registered so later active checks do not depend on directory scans.
7. Add an injectable clock or pure scheduling policy. Add internal counters or an injected discovery function for tests, not production log spam.
8. Preserve startup behavior: existing files seed offsets at EOF without replaying history.

Focused gates:

```bash
swift test --filter CodexDesktopSessionWatcherTests
swift test --filter FileEventMonitorTests
```

Then run the shared protocol.

## Tests

Extend the existing temporary root tests to cover:

- active transcript completion is found by an active-only reconcile without FSEvents;
- a new transcript in the newest date directory is found by recent discovery;
- a second-newest date directory is included;
- an old directory is excluded from recent discovery but found by full audit;
- full audit cadence is no more frequent than 300 ticks/seconds as configured;
- idle state does not keep a 1Hz timer alive;
- FSEvent discovery remains immediate;
- startup seeds old files at EOF without history replay;
- file truncation and deletion cleanup remain correct;
- no transcript file descriptor remains open between reads.

Use an injected discovery spy and assert enumerated roots/counts; do not make a five-minute test sleep.

## Before/after metrics

Build a temporary history fixture with at least 1,000 transcript files across 30 date directories and 2 active files. Measure 60 scheduler ticks before and after, recording:

- number of full-tree enumerations;
- number of directories and files visited;
- elapsed CPU time;
- completion-detection latency for the active file.

Targets:

- active completion detected within 1.5 seconds;
- recent new file detected within 10.5 seconds without FSEvents;
- at most one full-tree walk per five minutes;
- at least 90% fewer historical file visits over a 60-second simulated window;
- runtime `codex_session_descriptors=0` remains unchanged.

Repeat the real 30-sample measurement and a five-second sample with the user's current 265-file history.

## Done criteria

- Reconciliation scopes and cadence are explicit and tested.
- Reliability tests cover missed completion, missed recent creation, and rare full recovery.
- Historical visits drop by at least 90% in the synthetic window.
- Active completion latency and zero-descriptor guarantees pass.
- Full tests, release bundle, codesign, diff check, and raw before/after metrics pass.

## Escape hatches

- If Codex's directory layout is not consistently date-leaf based, STOP and derive recent directories from observed filesystem metadata; do not silently skip unknown layouts.
- If a reused old transcript can begin a turn without an FSEvent, add known-path modification tracking to recent scope before widening back to full-tree 10-second scans.
- If idle timer rescheduling creates teardown races, keep one low-frequency timer and test cancellation rather than creating multiple timers.

## Maintenance note

New recovery logic must be evaluated by files visited per unit time, not only event latency. Any cadence change should update the policy tests and this plan's benchmark assumptions.
