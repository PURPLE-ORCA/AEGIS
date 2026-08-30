# 003 — Restore brief collapse motion

- **Status**: IMPLEMENTED
- **Commit**: 3afa07a
- **Severity**: MEDIUM
- **Category**: easing

## Goal

Make island collapse visible again without allowing finished-card text to reflow while the panel narrows.

## Current code

```swift
// Sources/Aegis/Notch/NotchWindowController.swift
enum NotchPanelTransitionPolicy {
    static func duration(for state: NotchState) -> TimeInterval {
        if case .collapsed = state { return 0 }
        return NotchMotion.panelResizeDuration
    }
}
```

The atomic transition fixed visible text wrapping, but the collapse now reads as an instantaneous cut.

## Target code

```swift
// Sources/Aegis/Notch/NotchMotion.swift
enum NotchMotion {
    static let panelResizeDuration: TimeInterval = 0.20
    static let panelCollapseDuration: TimeInterval = 0.12
}

// Sources/Aegis/Notch/NotchWindowController.swift
enum NotchPanelTransitionPolicy {
    static func duration(for state: NotchState) -> TimeInterval {
        if case .collapsed = state { return NotchMotion.panelCollapseDuration }
        return NotchMotion.panelResizeDuration
    }
}
```

During the 120 ms collapse, hide the outgoing `content` subtree immediately when `state == .collapsed` but `presentedState != .collapsed`. Keep `NotchBackground`, clipping, and the window border mounted so the island shell visibly contracts without text receiving intermediate widths. Reduced Motion remains handled by `animatePanelToSize`, which snaps when macOS Reduce Motion is enabled.

## Steps

1. Add `NotchMotion.panelCollapseDuration = 0.12` beside `panelResizeDuration` in `Sources/Aegis/Notch/NotchMotion.swift`.
2. Return that token for `.collapsed` in `NotchPanelTransitionPolicy.duration(for:)`; retain `panelResizeDuration` for every other state.
3. Add a read-only collapse-presentation predicate to `NotchViewModel` or `NotchContentView` that is true only while logical state is collapsed and outgoing expanded content remains mounted.
4. Set the `content` subtree opacity to zero immediately during that interval. Do not hide `NotchBackground` or the window border, and do not animate the text opacity through intermediate panel widths.
5. Keep `completeCollapsePresentation()` and interruption behavior unchanged.
6. Update focused tests to assert 120 ms collapse, 200 ms expansion, and the collapse-presentation predicate before and after completion.

## Scope boundary

Do not change expansion duration, finished-card visibility, hover delays, session-card morphing, background rendering, dynamic-height measurement, or Reduced Motion behavior. The separate request to remove the visible `RUNWAY` label may be implemented in `RateLimitBar`, but must not change runway calculation, status copy, color, help text, or accessibility semantics.

## Verification

- Run focused auto-collapse and view-model tests, then the full test suite.
- Build the release app bundle and verify its signature.
- At normal speed, dismiss a multi-line finished card: the island shell should visibly contract for 120 ms while the reply text disappears before any wrapping can occur.
- Expand the island again: entry should retain its existing 200 ms smooth resize.
- Enable System Settings → Accessibility → Display → Reduce motion and confirm collapse snaps.
