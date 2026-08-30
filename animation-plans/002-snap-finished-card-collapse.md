# 002 — Snap finished-card collapse

- **Status**: IMPLEMENTED
- **Commit**: 031813f
- **Severity**: HIGH
- **Category**: performance

## Goal

Collapse the island atomically so finished-card text never reflows through narrower widths while the panel closes.

## Current code

```swift
// Sources/Aegis/Notch/NotchWindowController.swift:5
enum NotchPanelTransitionPolicy {
    static func duration(for _: NotchState) -> TimeInterval {
        NotchMotion.panelResizeDuration
    }
}
```

The current policy animates every target state for 0.20 seconds. During a transition to `.collapsed`, `presentedState` deliberately retains the finished content until the panel reaches its compact frame. SwiftUI therefore recomputes the finished card at every narrower window width and visibly wraps the reply before it disappears.

## Target code

```swift
// Sources/Aegis/Notch/NotchWindowController.swift
enum NotchPanelTransitionPolicy {
    static func duration(for state: NotchState) -> TimeInterval {
        if case .collapsed = state { return 0 }
        return NotchMotion.panelResizeDuration
    }
}
```

## Steps

1. Open `Sources/Aegis/Notch/NotchWindowController.swift` and locate `NotchPanelTransitionPolicy` near line 5.
2. Return `0` when the target state is `.collapsed`; retain `NotchMotion.panelResizeDuration` for expansion and other presentation changes.
3. Update the existing transition-policy regression test to assert that collapsed transitions are atomic and non-collapsed transitions keep the shared duration.
4. Do not add a second SwiftUI content animation during collapse. `completeCollapsePresentation()` must continue switching to compact content only after the panel reaches compact geometry.

## Scope boundary

Do not change expansion timing, session-card hover morphing, finished-card visibility duration, reduced-motion behavior, or dynamic-height measurement. This plan only prevents live text reflow during window collapse.

## Verification

- Run the focused transition-policy and finished-message tests.
- Run the full Swift test suite and release build.
- At normal speed, let a multi-line finished card auto-dismiss and manually dismiss it; the island must close immediately without any intermediate line wrapping.
- Expand the island afterward; entry must retain the existing smooth 0.20-second resize.
- Enable Reduce Motion and confirm collapse remains atomic.
