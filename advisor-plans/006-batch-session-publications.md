# 006 — Batch session-store publications

Status: IMPLEMENTED (`8b6eaa8`)
Priority: P1 main-thread and SwiftUI invalidation reduction
Baseline commit: `c9450ce`

## Why this matters

`SessionStore` publishes one value-typed dictionary. A normal hook separately mutates activity time, source, model, title, PID metadata, status, current tool, messages, and active timing. Every dictionary subscript mutation passes through `@Published`; Combine subscribers and broad SwiftUI observers can therefore receive several notifications for one logical event.

Current source of truth:

```swift
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [String: Session] = [:]
}
```

See `SessionStore.swift:17-20`, common mutations at `:158-242`, event transitions at `:273-450`, and active timer updates at `:452-462`. Broad consumers include `NotchContentView`, `SessionListView`, and the presence subscriber in `NotchWindowController.swift:73-80`.

## Required outcome

One accepted canonical `BridgeMessage` must commit at most one session-dictionary publication while preserving current state, event ordering, responder closures, queue behavior, and late-event/removal semantics.

## Scope

In scope:

- `Sources/CaesuraIsland/Session/SessionStore.swift`
- `Sources/CaesuraIsland/Session/Session.swift` only if a focused mutation helper requires it
- New/extended lifecycle and publication tests under `Tests/CaesuraIslandTests/`

Out of scope:

- Converting `Session` to `ObservableObject`
- Changing SessionStore's role as source of truth
- Redesigning UI observation or introducing a second store
- Changing canonical event vocabulary, pending-decision FIFO, terminal jumping, or sound semantics
- Optimizing `activeSessions` filtering in the same change
- The dirty finished-card files

## Implementation steps

1. Before refactoring, add characterization tests for every canonical event path that this plan will touch: session creation, user prompt, pre/post tool, Stop, SessionEnd, mirrored question, permission, notification, subagent start/stop, late event after completed, and suggestions-blob suppression.
2. Add a test subscriber to `store.$sessions.dropFirst()` and record publication count per message. Preserve these baseline counts in the handoff before changing code.
3. Refactor `handleMessage` into a transaction over one local `Session` value:
   - validate the canonical event before creating a session;
   - construct or copy the session once;
   - apply common metadata and event-specific state to the local value;
   - compute ordered `SessionEvent` values to emit;
   - assign `sessions[sessionId] = session` once;
   - emit queued events only after assignment so subscribers see final state.
4. Keep actions with external side effects—permission responses, terminal jumps, raw socket responses, pending removal task scheduling—outside the pure mutation block but preserve their exact current order relative to state assignment and `onEvent`.
5. Handle early-return paths explicitly. A Codex suggestions blob received after an already-idle Stop must produce no publication and no duplicate finished event.
6. Update `ensureSession` so it initializes or mutates the local transaction value rather than publishing independently. Preserve `sessionStarted` exactly once.
7. Keep scheduled removal as a separate logical transaction; one completion mark and one later removal publication are acceptable. Late hooks must still cancel removal and reactivate safely.
8. Do not use `objectWillChange.send()` manually around an already-`@Published` property; that would risk duplicate notification.

Run focused lifecycle tests after characterization and after each major refactor, then the full shared protocol.

## Tests

Add `SessionStorePublicationTests.swift`, following the `@MainActor` direct-message pattern in `SessionPresenceTests.swift:5-36`.

Required assertions:

- each accepted ordinary message publishes exactly once;
- ignored non-canonical and duplicate suggestions messages publish zero times;
- first message still emits `sessionStarted` before/alongside the correct state event exactly once;
- `onEvent` subscribers observe fully committed session state;
- permission/question closures remain callable once and are cleared correctly;
- a progress event resolves an orphaned pending response before emitting dismissal;
- late event cancels pending removal and survives the old task deadline;
- SessionEnd/completed removal semantics remain unchanged;
- active timer begins only on inactive→active and clears on active→inactive;
- a 1,000-event synthetic tool stream yields 1,000 publications, not a multiple.

Do not loosen existing lifecycle assertions merely to make publication counts pass.

## Before/after metrics

Create a deterministic XCTest performance helper that sends 1,000 alternating `PreToolUse`/`PostToolUse` messages to one store with sound/window consumers absent. Record:

- publication count;
- `onEvent` count;
- elapsed time;
- peak memory if available.

Then run a release-app workload with at least three busy sessions and capture:

- `./scripts/measure-performance.sh 30`;
- five-second `sample` counts beneath SwiftUI `GraphHost.flushTransactions`, `NSHostingView.layout`, and `reconcileWindowPresence`;
- visible card state before and after the stream.

Targets:

- exactly one publication per accepted message;
- zero publication for ignored messages;
- at least 50% lower synthetic event-processing time or a documented explanation if rendering, rather than store mutation, dominates;
- no increase in session-event count or runtime RSS/descriptors.

## Done criteria

- Characterization tests prove state and event semantics before/after.
- One-message/one-publication invariant passes across canonical paths.
- Pending responders, removal races, and duplicate completion guards remain correct.
- Synthetic and live before/after metrics are recorded.
- Full tests, release bundle, codesign, and diff check pass.

## Escape hatches

- If an external responder must run before state assignment to avoid blocking or protocol failure, STOP and document that exact event; do not move it speculatively.
- If copying `Session` invalidates closure identity or creates exclusivity errors, isolate the affected pending-decision transition and report it instead of converting the whole model to reference semantics.
- If one publication still causes multiple SwiftUI renders, complete this plan's invariant and report observation granularity as a separate follow-up; do not expand scope into a UI architecture rewrite.

## Maintenance note

Future canonical events should mutate a local session transaction and publish once. Reviewers should require a publication-count test whenever `handleMessage` gains another state transition.
