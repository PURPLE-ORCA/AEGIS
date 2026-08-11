# 002 — Filter and back off Hermes monitoring

Status: IMPLEMENTED (`5078847`, refinement `7e1ef98`)
Priority: P0 active Hermes CPU and battery
Baseline commit: `c9450ce`

## Why this matters

Hermes watches the entire `~/.hermes` root with file-level, no-defer FSEvents at 50ms latency. `FileEventMonitor` standardizes URLs and may query filesystem metadata before it applies Hermes' `state.db*` filter. A separate one-second timer prepares and executes the same SQLite query even when FSEvents is healthy. Runtime sampling identified the Hermes FSEvents queue as the hottest app-owned background path.

Current call site:

```swift
FileEventMonitor(
    root: self.root,
    label: "dev.caesura.island.hermes-desktop.events",
    includeFile: { $0.lastPathComponent.hasPrefix("state.db") }
) { [weak self] _ in
    self?.scheduleRefresh()
}
```

See `HermesDesktopSessionWatcher.swift:47-55`, `:82-105`, `:135-174`, and `FileEventMonitor.swift:53-66`, `:96-135`.

## Required outcome

Unrelated `.hermes` writes must not schedule SQLite work. Relevant `state.db`, `state.db-wal`, and `state.db-shm` changes must still be delivered promptly. Reconciliation must remain a reliability fallback but use an adaptive, low-wakeup cadence instead of unconditional 1Hz polling.

## Scope

In scope:

- `Sources/CaesuraIsland/Utilities/FileEventMonitor.swift`
- `Sources/CaesuraIsland/Hermes/HermesDesktopSessionWatcher.swift`
- `Tests/CaesuraIslandTests/FileEventMonitorTests.swift`
- `Tests/CaesuraIslandTests/HermesDesktopSessionWatcherTests.swift`

Out of scope:

- Changing Hermes' database schema or writing to it
- Changing restored-session semantics
- Removing reconciliation entirely
- Modifying Codex monitoring behavior except shared utility compatibility
- The current dirty finished-card files

## Implementation steps

1. Add an early path-filter seam to `FileEventMonitor` that can reject ordinary file events from their raw standardized path and flags before `URL.resourceValues` is consulted. Preserve must-rescan, dropped-event, root-changed, and late-root retarget behavior.
2. Use `kFSEventStreamEventFlagItemIsDir` and `ItemIsFile` when present. Only fall back to filesystem metadata when flags do not identify the item and directory knowledge is required.
3. Make Hermes explicitly accept only `state.db`, `state.db-wal`, and `state.db-shm`. A normal root-directory notification must not refresh SQLite unless it represents must-rescan/root-change recovery.
4. Make `readNewMessages()` return whether it observed new rows or a database-state transition. Do not change row ingestion order.
5. Replace the repeating one-second timer with one reschedulable safety timer:
   - relevant FSEvent: retain the existing ~60ms debounce;
   - after new rows: next safety check in 10 seconds;
   - database exists but no new rows: 15 seconds;
   - database absent: 30 seconds;
   - explicit `reconcileNow()`: immediate and deterministic.
6. Ensure `stop()` cancels the FSEvent debounce and the safety timer exactly once. Avoid queue reentrancy and retain cycles.

Run focused tests after the monitor change, then after watcher scheduling:

```bash
swift test --filter FileEventMonitorTests
swift test --filter HermesDesktopSessionWatcherTests
```

Then run the shared verification protocol.

## Tests

Extend the existing temporary-directory and temporary-SQLite patterns.

Required cases:

- unrelated top-level `.hermes` files and directories do not call `onChange`;
- append/create events for all three SQLite filenames do call it;
- a must-rescan/root-change event still produces recovery work;
- a root created after monitoring starts still retargets and reports the database;
- multiple WAL changes inside the debounce window produce one read;
- explicit reconciliation still catches an append without FSEvents;
- absent-database retry uses the slow cadence;
- `stop()` prevents delayed refresh after teardown.

Expose scheduler decisions through a pure policy or injected clock. Do not make unit tests sleep 10–30 seconds.

## Before/after metrics

With Hermes Desktop actively writing its database:

1. Run `sample <pid> 5 1` before and after.
2. Count stacks containing `dev.caesura.island.hermes-desktop.events`, `FileEventMonitor.handle`, `readNewMessages`, and `sqlite3_prepare_v2`.
3. Record 30-sample CPU/RSS/descriptor output.
4. Confirm a real Hermes prompt/tool/finish cycle reaches the UI within 500ms through FSEvents.
5. Leave Hermes idle for 60 seconds and confirm no more than four safety SQLite reads occur.

Success target: at least 70% fewer Hermes monitor samples during the same write workload and no missed lifecycle event.

## Done criteria

- Focused and full tests pass.
- Unrelated `.hermes` activity schedules zero database reads.
- Idle safety polling is no faster than the specified adaptive cadence.
- Event-driven updates remain sub-500ms in runtime QA.
- Before/after sample and aggregate metrics are included in the handoff.

## Escape hatches

- If FSEvent flags omit enough information to filter safely, STOP and preserve a metadata fallback for ambiguous events; do not drop them silently.
- If WAL writes do not reliably emit one of the accepted paths on the supported macOS version, STOP and document observed paths before widening the filter.
- If adaptive polling causes a reproducible missed completion, keep the reliability bound and report the failing event sequence instead of removing fallback coverage.

## Maintenance note

`FileEventMonitor` is shared with Codex. New filtering must remain opt-in or behavior-compatible so recursive JSONL discovery and late-root recovery do not regress.
