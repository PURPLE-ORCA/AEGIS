# Polish island interaction timing, toolbar, and resize motion

Status: IMPLEMENTED in isolated branch `codex/island-interaction-polish`

Implementation commits: `1b9ad65`, `4a5267b`

Review verdict: accepted after 156-test full suite, release build, signed bundle verification, focused policy rerun, and clean diff check. Runtime visual inspection remains pending.

Written against: `08965a3`

## Outcome

Implement the requested Aegis island polish as one cohesive UI change:

- begin closing the expanded island immediately when the pointer leaves its perimeter;
- double the compact Session Finished card visibility from 3 seconds to 6 seconds and its bounded hover lifetime from 15 seconds to 30 seconds;
- move the multi-agent filter into the top-right toolbar and render it with icons only;
- increase the top-left usage text slightly for visibility;
- reduce the visual gap between the sound and settings buttons;
- animate expand and shrink as a smooth layout animation / continuity transition without restoring the blank-panel regression or adding persistent animation work.

## Current behavior and constraints

`Sources/Aegis/Notch/NotchViewModel.swift` currently schedules a 0.6-second delay after `mouseExited()`, shows finished cards for 3 seconds, and bounds hovered finished cards to 15 seconds:

```swift
static let finishedHoverCeiling: TimeInterval = 15

func showFinished(session: Session) {
    // ...
    scheduleAutoCollapse(delay: 3.0)
}

func mouseExited() {
    isHovered = false
    // permission/question states are excluded
    if isExpanded {
        scheduleAutoCollapse()
    }
}
```

`Sources/Aegis/Notch/NotchWindowController.swift` uses a display-link-driven frame animation for expansion, but `NotchPanelTransitionPolicy` returns zero duration for `.collapsed`. Commit `7623687` added that snap specifically because switching SwiftUI to compact content before the old expanded window finished shrinking produced a blank expanded panel. Preserve this regression fix structurally: do not merely change the collapsed duration from `0` to a nonzero value.

`Sources/Aegis/Notch/Views/SessionListView.swift` renders the usage bar in the top row, sound/settings buttons on the right, and a second text-heavy filter-chip row beneath it. The toolbar `HStack(spacing: 8)` also creates the current sound/settings gap.

`Sources/Aegis/Notch/Views/RateLimitBar.swift` uses 10-point text for window labels, percentages, durations, and runway status, with an 8-point `RUNWAY` label.

## Implementation

1. Add named interaction timing constants in `NotchViewModel` rather than scattering new literals. The expanded mouse-exit delay must be zero/immediate, finished-card delay must be 6 seconds, and finished hover ceiling must be 30 seconds. Permission and question states must remain open until explicit user action. Entering an expanded island must continue to cancel ordinary auto-collapse. A finished card that has never been hovered should remain visible for 6 seconds; after the pointer enters and then exits, shrinking may begin immediately.

2. Implement a two-phase, interruptible collapse so outgoing expanded content stays mounted during the resize and compact content replaces it only when the frame reaches `collapsedSize`. Keep AppKit as the sole window-size owner and keep the existing fixed container below `NSHostingView`. Use the existing `CADisplayLink`, `display: false`, top-edge anchoring, Reduce Motion handling, and invalidation discipline. Starting a new expansion or presentation while shrink is in flight must cancel/redirect the transition cleanly. Do not add a persistent timer, physics loop, polling, or per-frame SwiftUI state publication.

3. Use a short non-bouncy layout animation / continuity transition. Prefer a smooth ease-in-out or asymmetric cubic curve over a spring because this is a frequently used resize and the user prioritizes performance. The frame animation must begin on pointer exit without a pre-delay. Reduced Motion should snap atomically. Preserve the existing no-recursive-constraint behavior and avoid a large blank or stale panel at any point.

4. In `SessionListView`, remove the separate filter row. Add an icon-only filter group to the top-right toolbar, before the sound/settings controls, only when at least two providers are present. Each provider button uses `ProviderIcon`; the All button uses a clear system symbol such as `square.grid.2x2`. Preserve selection tint/stroke, stale-selection recovery, hit targets, and full accessibility labels/values. No visible filter text or counts.

5. Keep the usage bar at top left. Increase its main text from 10 to 11 points and `RUNWAY` from 8 to 9 points; increase the no-data text from 9 to 10 points. Keep weights, colors, labels, and line behavior otherwise unchanged.

6. Group sound and settings in a nested `HStack(spacing: 0)` or otherwise reduce only their inter-button gap while preserving the existing 28-by-28 hit areas and accessibility labels. Do not compress the gap between unrelated toolbar groups.

7. Update tests. Extend `AutoCollapsePolicyTests` to assert the new transition/timing policy and immediate mouse-exit collapse behavior using deterministic policy functions/constants rather than wall-clock sleeps. Add or extend session-list presentation tests for icon-only filter metadata where practical. Preserve all existing session-card, fitted-height, finished-message, presence, and Reduce Motion behavior.

## Files in scope

- `Sources/Aegis/Notch/NotchViewModel.swift`
- `Sources/Aegis/Notch/NotchWindowController.swift`
- `Sources/Aegis/Notch/NotchContentView.swift` only if needed for the two-phase render state
- `Sources/Aegis/Notch/NotchMotion.swift` for named motion constants/curve
- `Sources/Aegis/Notch/Views/SessionListView.swift`
- `Sources/Aegis/Notch/Views/RateLimitBar.swift`
- focused files under `Tests/AegisTests/`

## Out of scope

- Session-card content and hover detail layout
- keep-awake / power management
- watcher or transcript parsing behavior
- settings UI
- theme redesign
- user-owned `plans/README.md` and `plans/003-live-agent-activity-subtitle.md`
- installation, commit to `main`, or push

## Verification

Run from the isolated executor worktree:

```bash
swift test
swift build -c release
git diff --check
```

Expected results: all tests pass, release build succeeds, and `git diff --check` is silent.

Then build and inspect the local bundle if the environment permits:

```bash
./scripts/build-app.sh 0.1.0
codesign --verify --deep --strict build/Aegis.app
```

Manual acceptance:

- expansion is smooth and top-anchored;
- pointer exit starts shrink immediately;
- outgoing content remains visible during shrink and no large blank panel appears;
- Reduce Motion snaps without animated intermediate frames;
- finished card remains for about 6 seconds when untouched and never remains hovered beyond 30 seconds;
- multi-provider filter is top-right and icon-only;
- top-left quota text is visibly larger;
- sound/settings controls sit closer together without smaller hit targets;
- idle CPU has no new recurring activity after animations settle.

## Escape hatches

- If a two-phase collapse cannot preserve outgoing content without reintroducing the recursive hosting constraint path, stop and report the exact lifecycle conflict; do not restore naive animated `.collapsed` resizing.
- If toolbar width cannot hold every active provider icon at 600 points, use a compact icon-only menu with the selected provider icon as its label; do not restore visible filter text or a second row.
- If runtime visual inspection is unavailable, report source/test/build evidence separately and do not claim the blank-panel behavior was visually verified.
