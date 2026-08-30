# 004 — Restore instant finished-card collapse

- **Status**: IMPLEMENTED
- **Written against**: `8177c18`
- **Implementation commit**: `7d7c0ee`
- **Severity**: HIGH
- **Category**: easing, performance

## Goal

Close the finished card atomically so the reply never receives intermediate narrow widths, while preserving the existing 200 ms expansion motion.

Follow-up: `27c3077` kept collapse atomic while reducing finished-card opening from 200 ms to 120 ms and its visibility lease from ten seconds to five seconds. Other panel expansion remains 200 ms.

## Current code

`Sources/Aegis/Notch/NotchMotion.swift:3-9` defines a dedicated 120 ms collapse duration:

```swift
enum NotchMotion {
    static let panelResizeDuration: TimeInterval = 0.20
    static let panelCollapseDuration: TimeInterval = 0.12
    static let sessionCardHoverDelay: TimeInterval = 0.08
    static let sessionCardHoverExitGrace: TimeInterval = 0.06
    static let sessionCardMorphDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.12
}
```

`Sources/Aegis/Notch/NotchWindowController.swift:5-9` applies that duration whenever the panel targets `.collapsed`:

```swift
enum NotchPanelTransitionPolicy {
    static func duration(for state: NotchState) -> TimeInterval {
        if case .collapsed = state { return NotchMotion.panelCollapseDuration }
        return NotchMotion.panelResizeDuration
    }
}
```

`NotchWindowController.animatePanelToSize` drives both width and height through every intermediate frame. Even though `NotchContentView` attempts to hide outgoing content, the AppKit window begins narrowing in the same state-change turn, so finished-card text can visibly reflow inward before SwiftUI presents the compact subtree.

## Target code

Remove the obsolete collapse-duration token from `Sources/Aegis/Notch/NotchMotion.swift`:

```swift
enum NotchMotion {
    static let panelResizeDuration: TimeInterval = 0.20
    static let sessionCardHoverDelay: TimeInterval = 0.08
    static let sessionCardHoverExitGrace: TimeInterval = 0.06
    static let sessionCardMorphDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.12
}
```

Make the collapsed target atomic in `Sources/Aegis/Notch/NotchWindowController.swift`:

```swift
enum NotchPanelTransitionPolicy {
    static func duration(for state: NotchState) -> TimeInterval {
        if case .collapsed = state { return 0 }
        return NotchMotion.panelResizeDuration
    }
}
```

Keep the existing zero-duration branch in `animatePanelToSize`: it sets the final compact frame with `display: false` and immediately invokes `completeCollapsePresentation()`. Do not add a replacement fade, scale, spring, or delayed content swap. The system response should snap.

## Steps

1. Open `Sources/Aegis/Notch/NotchMotion.swift` and delete only `NotchMotion.panelCollapseDuration`.
2. Open `Sources/Aegis/Notch/NotchWindowController.swift` and change the `.collapsed` policy result from `NotchMotion.panelCollapseDuration` to the literal zero-duration value `0`.
3. Preserve `NotchContentView`'s `hidesOutgoingContentDuringCollapse` opacity guard and `NotchViewModel.completeCollapsePresentation()`. They remain useful transition bookkeeping and interruption protection even though normal collapse now completes in one turn.
4. Update `Tests/AegisTests/AutoCollapsePolicyTests.swift`: rename `testPanelUsesBriefCollapseAndKeepsSmoothExpansion` to `testPanelSnapsCollapseAndKeepsSmoothExpansion`, remove the `panelCollapseDuration == 0.12` assertion, and assert `NotchPanelTransitionPolicy.duration(for: .collapsed) == 0`.
5. Keep the assertions that expansion and finished-state presentation use `NotchMotion.panelResizeDuration == 0.20`.
6. Do not add new tests; the existing transition-policy test is the main path and already covers the critical regression.

## Scope boundary

Do not change the dual-monitor 350 ms hover-intent delay, panel expansion duration, finished-card ten-second visibility lease, finished-card Markdown layout, session-card hover animation, permission/question presentation, dynamic-height measurement, or Reduced Motion handling. Do not animate opacity, scale, blur, padding, width, or height as a replacement for the removed collapse.

Do not edit `plans/`, `advisor-plans/`, or the earlier animation plan bodies. Plan 003 remains historical evidence for why the 120 ms contraction was introduced; this plan supersedes its runtime behavior.

## Verification

- Run `swift test --filter AutoCollapsePolicyTests` and expect all focused tests to pass.
- Run `swift test` and expect the full suite to pass.
- Run `swift build -c release`.
- Run `git diff --check`.
- Run `./scripts/build-app.sh 0.1.0`.
- Run `codesign --verify --deep --strict build/Aegis.app`.
- Install and relaunch the exact rebuilt bundle before judging motion; verify the installed and workspace executable hashes match.
- Normal-speed feel-check: let an expanded, multi-paragraph finished reply auto-dismiss. The 600-point card must become the compact island in one visual update with no narrowing shell, inward text squeeze, added wrapping, or intermediate blank frame.
- Manual feel-check: dismiss/open the session from the finished card and confirm the same atomic close path.
- Expansion regression check: open the island afterward and confirm entry still uses the existing smooth 200 ms resize.
- Interruption check: trigger another permission, question, or finished presentation at the collapse boundary. The new presentation must win and must not be overwritten by stale collapse completion.
- Reduced Motion check: collapse remains atomic; expansion continues to honor the existing system setting.
