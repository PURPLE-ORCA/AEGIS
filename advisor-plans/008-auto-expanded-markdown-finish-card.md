# Auto-expand the Markdown finish card for ten seconds

Status: IMPLEMENTED in `85828d4`; installed to `/Applications/Aegis.app`

Follow-up: `27c3077` reduced the finished-card visibility lease from ten seconds to five seconds and its opening resize from 200 ms to 120 ms.

Written against: `dcf2422`

## Outcome

When an agent finishes a run, Aegis should immediately present the existing full completion card rather than its compact two-line preview. The expanded card should remain readable for at least 10 seconds, render the final reply through Aegis's existing lightweight Markdown view, remain bounded and scrollable for long replies, and preserve the current interaction ceiling and low-idle-cost behavior.

This is a presentation change only. The provider watchers already deliver the final assistant message into `Session.lastAssistantMessage`; no transcript, database, hook, or provider integration changes are required.

## Vetted findings

| # | Finding | Category | Impact | Effort | Fix risk | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Finished sessions start in the compact two-line preview because `FinishedView.isExpanded` defaults to `false`; the full reply is only mounted after the chevron is clicked. | Correctness / UX | High | S | Low | `Sources/Aegis/Notch/Views/FinishedView.swift:13-31`, `Sources/Aegis/Notch/Views/FinishedView.swift:84-86` |
| 2 | Aegis already renders the expanded reply with `MarkdownText`; adding another parser or package would duplicate behavior and increase binary/runtime cost. | Performance / architecture | High | S | Low | `Sources/Aegis/Notch/Views/FinishedView.swift:178-226`, `Sources/Aegis/Notch/Views/MarkdownText.swift:3-220` |
| 3 | The untouched finish card currently dismisses after 6 seconds, and `mouseExited()` can replace that timer with an immediate collapse. That does not guarantee the requested 10-second reading window. | Correctness / UX | High | S | Medium | `Sources/Aegis/Notch/NotchViewModel.swift:20-22`, `Sources/Aegis/Notch/NotchViewModel.swift:205-215`, `Sources/Aegis/Notch/NotchViewModel.swift:280-306` |
| 4 | Long replies are already bounded to a 360-point scroll viewport and the panel to 560 points. These caps should remain; expanding the window to the entire reply would harm usability and force unnecessary layout work. | Performance / UX | High | S | Low | `Sources/Aegis/Notch/Views/FinishedView.swift:216-218`, `Sources/Aegis/Notch/Views/FinishedView.swift:292-305` |

## Implementation

1. Make each newly presented `FinishedView` start expanded. Treat the automatic expansion differently from the user's manual expansion action: it must not call the existing `onToggleExpand(true)` path, because that path cancels auto-collapse indefinitely. Keep the current compact card available when the user explicitly presses the collapse chevron.

2. Ensure a new completed session always resets the local card state to expanded, even if SwiftUI reuses the previous `FinishedView` identity after the prior card was manually collapsed. Prefer giving the finished view a session-scoped identity at its construction site in `NotchContentView`, or reset the local state on a `session.id` change. Do not use a global singleton flag.

3. Change `NotchViewModel.finishedCardVisibilityDuration` from 6 seconds to 10 seconds. Preserve the existing single cancellable `Task`; do not add a timer, polling loop, display link, or per-frame publication.

4. Guarantee the initial reading window. A pointer exit during the first 10 seconds must not cancel the scheduled finish-card lease and replace it with the ordinary zero-delay island collapse. Keep immediate mouse-exit collapse for `.expanded` session-list state. For `.finished`, let the existing 10-second task remain armed. If the pointer is over the finish card when that task fires, preserve the current bounded rearm behavior up to `finishedHoverCeiling` (30 seconds); once the pointer leaves after the initial lease, the already-armed recheck may collapse within `autoCollapseRearmInterval`.

5. Keep the expanded reply wired to the existing `MarkdownText` view. Do not add a third-party Markdown dependency and do not render WebKit/HTML. Preserve the current features and fallback behavior: fenced code, inline code, emphasis, links, headings, bullets/task items, quotes, tables, selectable text, and plain text when parsing cannot interpret input.

6. Preserve `FinishedReplyWindowLayout.maximumReplyHeight == 360` and `maximumWindowHeight == 560`. The requirement is to show the full completion card, not to resize the island to the unbounded height of the entire message. Long replies remain scrollable. Short replies continue to fit their measured content rather than receiving a large fixed height.

7. Avoid visible two-stage content switching. The first mounted finished content must be the details view, and its preference-driven height measurement should continue to resize the AppKit window through the existing dynamic-height path. Do not restore a default tall panel height, do not render an invisible duplicate Markdown tree for measurement, and do not animate text through narrowing widths during collapse.

8. Keep the completion snapshot semantics. Render from `finishedSessionSnapshot` when the live session disappears so the full Markdown reply cannot become blank during the 10-second lease. Do not persist parsed Markdown or final-card UI state in `SessionStore`.

## Tests

Extend the existing focused tests instead of adding timing sleeps:

- In `Tests/AegisTests/AutoCollapsePolicyTests.swift`, assert `finishedCardVisibilityDuration == 10`, the 30-second hover ceiling remains unchanged, ordinary expanded state still has a zero mouse-exit delay, and finished state does not schedule an immediate mouse-exit collapse during its presentation lease.
- Add a pure policy test showing that an unhovered finished card collapses when its scheduled 10-second check fires, while a hovered card rearms only up to the existing ceiling.
- In `Tests/AegisTests/FinishedMessagePresentationTests.swift`, add coverage for the new initially-expanded/session-reset presentation policy at the closest testable seam. If `@State` itself cannot be tested without UI hosting, extract only a small pure `FinishedCardPresentationPolicy` value; do not introduce a new coordinator or view model.
- Extend `Tests/AegisTests/RegressionBaselineTests.swift` with representative final-message Markdown covering at least a heading, bullet/task item, fenced code block, and ordinary prose in source order. Test the existing parser output rather than snapshotting platform typography.
- Preserve the snapshot-retention and fitted-height regression tests.

## Files in scope

- `Sources/Aegis/Notch/NotchViewModel.swift`
- `Sources/Aegis/Notch/NotchContentView.swift`
- `Sources/Aegis/Notch/Views/FinishedView.swift`
- `Sources/Aegis/Notch/Views/MarkdownText.swift` only if a narrowly scoped parser regression is found while adding the requested Markdown fixtures
- `Tests/AegisTests/AutoCollapsePolicyTests.swift`
- `Tests/AegisTests/FinishedMessagePresentationTests.swift`
- `Tests/AegisTests/RegressionBaselineTests.swift`

## Explicitly out of scope

- Codex or Hermes transcript/database watchers
- `SessionStore` persistence or canonical event changes
- installing a Markdown package or using WebKit
- removing the compact finished-card mode
- changing the 30-second maximum hovered lifetime
- changing the 360-point reply viewport or 560-point panel cap
- keep-awake behavior, sounds, settings, themes, and active-session cards
- user-owned files under `plans/` and `animation-plans/`

## Verification

Run from the repository root:

```bash
swift test
swift build -c release
git diff --check
./scripts/build-app.sh 0.1.0
codesign --verify --deep --strict build/Aegis.app
```

Expected results: all tests pass, the release build succeeds, `git diff --check` is silent, and the built bundle passes strict signing verification.

Manual acceptance with one short Markdown reply and one reply longer than the viewport:

- completion opens directly to the full details card with formatted Markdown;
- the card does not first flash the compact two-line preview;
- untouched completion remains visible for approximately 10 seconds;
- moving the pointer out before 10 seconds does not close it early;
- hovering at 10 seconds keeps it readable, but never beyond the existing 30-second ceiling;
- the collapse chevron still produces the compact card and Dismiss still closes immediately;
- long content scrolls inside the existing cap; short content fits without empty vertical space;
- collapse does not wrap text through narrowing widths or show a blank large panel;
- after the card disappears and animations settle, Aegis has no new recurring CPU activity.

For a comparable runtime check, launch the exact release bundle and use the existing measurement script with the same live-session and display conditions before and after:

```bash
open -n "$PWD/build/Aegis.app"
pid=$(pgrep -f "$PWD/build/Aegis.app/Contents/MacOS/Aegis" | head -1)
./scripts/measure-performance.sh 30 "$pid"
```

## Escape hatches

- If the expanded body is not receiving the final assistant message, stop and report the exact provider/event that produced an empty `lastAssistantMessage`; do not compensate by replaying or rescanning transcript history in the UI layer.
- If session-scoped view identity causes the whole panel shell to remount, use an `onChange(of: session.id)` state reset inside `FinishedView`; do not move finished-card state into `SessionStore`.
- If a Markdown construct outside the renderer's documented subset is still raw, report that exact construct before widening `MarkdownText`; do not claim full CommonMark support or add a dependency as an incidental fix.
- If visual inspection is unavailable, report source/test/build evidence separately and do not claim the 10-second timing or transition was visually verified.

## Maintenance note

The presentation duration, hover ceiling, and mouse-exit behavior form one policy. Future timing changes should update the named constants and deterministic policy tests together. Markdown remains a deliberately lightweight local renderer for compact native UI; keep new syntax additions bounded and covered by parser tests, and avoid work proportional to transcript history.
