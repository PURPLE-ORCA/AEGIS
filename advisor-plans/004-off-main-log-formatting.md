# 004 — Move log formatting off the main thread

Status: IMPLEMENTED (`a701379`)
Priority: P1 low-risk main-thread reduction
Baseline commit: `c9450ce`

## Why this matters

The logger owns a utility queue and a reusable file handle, but it creates a localized timestamp before dispatching to that queue. Watcher messages call `Log.info` from the main actor. A runtime sample captured ICU/`NSDateFormatter` construction inside `CodexDesktopSessionWatcher.emit` → `AppDelegate` → `Log.enqueue` on the main thread.

Current code in `Sources/CaesuraIsland/Utilities/Logger.swift:28-37`:

```swift
let timestamp = DateFormatter.localizedString(
    from: Date(), dateStyle: .none, timeStyle: .medium
)
let line = "[\(timestamp)] [\(level)] \(message)\n"
queue.async {
    writer.write(line)
}
```

## Required outcome

Calling `Log.info` or `Log.error` must do only bounded string capture and asynchronous enqueue work on the caller. Timestamp formatting and line construction must happen on the logger queue using a reusable, queue-confined formatter.

## Scope

In scope:

- `Sources/CaesuraIsland/Utilities/Logger.swift`
- `Tests/CaesuraIslandTests/FileLogWriterTests.swift` or a new focused logger test file

Out of scope:

- Changing log destinations, rotation size, levels, or message contents
- Removing useful watcher logs
- Introducing OSLog or a third-party logging framework
- Editing AppDelegate call sites unless required for a test seam
- The dirty finished-card files

## Implementation steps

1. Add a queue-confined `LogLineFormatter` instance owned by `Log`. It may wrap one configured `DateFormatter`, but it must never cross queues.
2. Capture `Date`, level, and message at `enqueue` call time, then dispatch those values immediately. Perform timestamp formatting and complete line construction inside `queue.async`.
3. Preserve the existing user-visible localized medium-time shape. Set locale/calendar/time zone behavior explicitly only if doing so matches the current output; do not silently switch formats in a performance change.
4. Keep `FileLogWriter` queue-confined and reusable. Do not add a lock around every write.
5. Make `shutdown()` drain queued entries before closing the writer, preserving current `queue.sync` semantics.
6. If tests need deterministic time, inject a date or formatter into `LogLineFormatter`, not into all production call sites.

Run:

```bash
swift test --filter FileLogWriterTests
swift test
```

Then run the shared release/bundle verification.

## Tests

Cover:

- a fixed date produces one correctly structured line with level and message;
- multiple writes retain FIFO order;
- rotation still retains complete lines;
- shutdown after queued writes leaves all accepted messages on disk;
- concurrent producers do not corrupt or interleave a line;
- the formatter instance is only exercised from its owning queue, using a debug assertion or injected spy if practical.

Match the existing temporary-directory cleanup pattern in `FileLogWriterTests.swift:5-20`.

## Before/after metrics

Before and after, generate a bounded burst of 1,000 logger calls from the main actor in a test helper and measure enqueue duration separately from queue drain duration. The main-actor enqueue target is at least 5× faster than the current implementation.

Runtime gate:

1. Keep several Codex sessions active for five seconds.
2. Capture `sample <pid> 5 1`.
3. Search the sample for `NSDateFormatter`, `CFDateFormatter`, and ICU date formatting beneath a main-thread watcher/AppDelegate stack.

After implementation, there must be no date-formatting stack beneath the main event path. Formatter work on `com.caesura-island.logger` is acceptable.

## Done criteria

- No timestamp formatting or line construction occurs before `queue.async`.
- Output ordering, rotation, and shutdown durability tests pass.
- Main-thread runtime samples contain no logger date formatting.
- Shared verification and 30-sample metrics are recorded.

## Escape hatches

- If exact localized output cannot be made deterministic in tests, assert stable delimiters/level/message and separately test FIFO behavior; do not hard-code the developer machine's locale.
- If shutdown can be called from the logger queue, STOP and add a queue-specific guard before using `sync`; do not introduce a deadlock.
- If `DateFormatter` proves unsafe under the proposed ownership, keep it strictly inside the serial queue rather than adding broad locking.

## Maintenance note

Future expensive metadata—source location formatting, JSON encoding, privacy redaction—must also be performed on the logger queue. Caller-side string interpolation already supplied by a call site is outside this plan.
