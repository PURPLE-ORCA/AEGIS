# 002 — Stabilize session-card hover motion

- **Status**: DONE
- **Commit**: 5a430e6
- **Severity**: HIGH
- **Category**: interruptibility, performance, easing

## Goal

Make a session node expand and shrink with one simple, interruptible 180ms morph while the native Aegis panel remains geometrically stable under the pointer.

## Current code

`Sources/Aegis/Notch/Views/SessionCardView.swift:25-31,67-81,93-115` currently animates the card's measured height and publishes every intermediate layout value:

```swift
private func morphAnimation(expanding: Bool) -> Animation {
    if reduceMotion {
        return NotchMotion.reducedSessionCard
    }

    return expanding ? NotchMotion.sessionCard : NotchMotion.sessionCardCollapse
}

detailContent
    .fixedSize(horizontal: false, vertical: true)
    .background {
        GeometryReader { geometry in
            Color.clear.preference(
                key: SessionCardDetailHeightKey.self,
                value: geometry.size.height
            )
        }
    }
    .frame(height: detailPresentation.height, alignment: .top)
    .opacity(detailPresentation.opacity)
    .clipped()
    .allowsHitTesting(showsDetails)
```

`Sources/Aegis/Notch/Views/SessionListView.swift:167-208` measures the changing list and forwards every height:

```swift
.background {
    GeometryReader { geometry in
        Color.clear.preference(
            key: SessionListContentHeightKey.self,
            value: geometry.size.height
        )
    }
}

.onPreferenceChange(SessionListContentHeightKey.self) { height in
    guard height > 0 else { return }
    measuredListHeight = height
    reportContentHeight(chromeHeight: measuredChromeHeight, listHeight: height)
}
```

`Sources/Aegis/Notch/NotchWindowController.swift:97-103,209-228` converts those intermediate SwiftUI frames into native window resizes:

```swift
viewModel.$dynamicExpandedHeight
    .dropFirst()
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in
        self?.repositionExpandedContentWindow()
    }
    .store(in: &cancellables)

panel.setFrame(
    NSRect(
        x: screen.midX - target.width / 2,
        y: screen.maxY - target.height,
        width: target.width,
        height: target.height
    ),
    display: false
)
```

This is the highest-confidence remaining cause of the live flicker: the card's hover target drives a native window-frame mutation on every animation frame. Native frame changes rebuild tracking geometry and can emit a transient hover exit, which immediately reverses the card and repeats the cycle. Pure pointer hover could not be automated reliably, so the executor must confirm this hypothesis with the frame-stability check below.

## Target code

Keep `SessionCardDetailPresentation`, `detailContentHeight`, the persistent detail subtree, and the title/runtime compact row already present in the working tree. Remove only the outer-window feedback path.

### 1. Use one morph token

In `Sources/Aegis/Notch/NotchMotion.swift`, replace the asymmetric session-card timings with the strong on-screen-movement curve from the motion audit catalog:

```swift
enum NotchMotion {
    static let sessionCardHoverDelay: TimeInterval = 0.08
    static let sessionCardMorphDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.12

    static var sessionCardMorph: Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: sessionCardMorphDuration)
    }

    static var reducedSessionCard: Animation {
        .easeOut(duration: reducedMotionDuration)
    }
}
```

In `Sources/Aegis/Notch/Views/SessionCardView.swift`, simplify the animation selection:

```swift
private var morphAnimation: Animation {
    reduceMotion ? NotchMotion.reducedSessionCard : NotchMotion.sessionCardMorph
}
```

Use `withAnimation(morphAnimation)` for both hover entry and hover exit. Preserve the cancellable 80ms entry-intent task and immediate exit handling.

### 2. Give the expanded session list a stable native size

In `Sources/Aegis/Notch/NotchViewModel.swift`:

```swift
// Delete dynamicExpandedHeight.
@Published var dynamicPermissionHeight: CGFloat? = nil
@Published var dynamicFinishedHeight: CGFloat? = nil

var currentSize: NSSize {
    switch state {
    case .collapsed:
        return Self.collapsedSize
    case .expanded:
        return Self.expandedSize
    case .finished:
        return NSSize(width: 600, height: dynamicFinishedHeight ?? Self.finishedSize.height)
    case .permission:
        return NSSize(width: 600, height: dynamicPermissionHeight ?? Self.permissionSize.height)
    case .question:
        return Self.questionSize
    }
}
```

Delete writes to `dynamicExpandedHeight` in `expand()` and `collapse()`. Delete `updateExpandedContentHeight(_:)` entirely.

In `Sources/Aegis/Notch/Views/SessionListView.swift`, remove `onContentHeightChange`, `measuredListHeight`, `SessionListContentHeightKey`, `reportContentHeight`, and all content-height preference publication. Keep `measuredChromeHeight`, because provider-filter chrome can legitimately change outside card hover. Give the scroll viewport the remaining fixed panel height:

```swift
ScrollView(showsIndicators: false) {
    // Existing provider/card content remains unchanged.
}
.frame(height: SessionListWindowLayout.viewportHeight(
    chromeHeight: measuredChromeHeight
))

enum SessionListWindowLayout {
    static let minimumHeight: CGFloat = 104
    static let maximumHeight: CGFloat = 320

    static func viewportHeight(chromeHeight: CGFloat) -> CGFloat {
        max(1, maximumHeight - chromeHeight)
    }
}
```

In `Sources/Aegis/Notch/NotchContentView.swift`, construct `SessionListView` without `onContentHeightChange`:

```swift
SessionListView(
    sessionStore: sessionStore,
    rateLimitStore: rateLimitStore,
    settingsStore: settingsStore,
    onCollapse: { viewModel.collapse() },
    onOpenSettings: onOpenSettings
)
```

In `Sources/Aegis/Notch/NotchWindowController.swift`, delete the `viewModel.$dynamicExpandedHeight` subscription and delete `repositionExpandedContentWindow()`. The existing `viewModel.$state` subscription must remain; it performs the single collapsed-to-expanded native window animation through `repositionWindow()`.

### 3. Lock down the regression

In `Tests/AegisTests/SessionListProjectionTests.swift`, replace the dynamic-content fitting test with:

```swift
func testExpandedSessionListUsesStableViewportHeight() {
    XCTAssertEqual(
        SessionListWindowLayout.viewportHeight(chromeHeight: 44),
        SessionListWindowLayout.maximumHeight - 44
    )
    XCTAssertEqual(
        SessionListWindowLayout.viewportHeight(chromeHeight: 76),
        SessionListWindowLayout.maximumHeight - 76
    )
}
```

Keep the existing `SessionCardPresentationTests.testCollapsedDetailPresentationKeepsContentMountedAtZeroHeight`. Add a source-level integration assertion only if a correct native-window test seam can be exposed: while `NotchState.expanded` is unchanged, changing card detail presentation must not mutate `NotchViewModel.currentSize`.

## Steps

1. Preserve the four existing uncommitted UI files and the title/runtime row; do not reset or replace them.
2. Update `NotchMotion` and `SessionCardView` to use one 180ms `cubic-bezier(0.77, 0, 0.175, 1)` equivalent for both directions.
3. Remove dynamic expanded-list window height from `NotchViewModel`, `NotchContentView`, `SessionListView`, and `NotchWindowController` exactly as specified above.
4. Update the focused layout tests before running the full suite.
5. Search for `dynamicExpandedHeight`, `updateExpandedContentHeight`, `SessionListContentHeightKey`, and `repositionExpandedContentWindow`; all four must have zero remaining references.
6. Build, sign, and replace `/Applications/Aegis.app` using the repo's existing safe install workflow.
7. Run the live feel-check with one session and with at least three sessions.

## Scope boundary

Do not change the session name/runtime compact row, card information architecture, mascot artwork or animation, click-to-open behavior, provider sorting, provider-section collapse motion, global collapsed-to-expanded notch animation, finished popup, permission/question sizing, sound features, or session lifecycle code. Do not add debounce to hover exit; the fix removes the native tracking invalidation instead of masking it with latency.

## Verification

- Run `swift test --filter SessionCardPresentationTests`.
- Run `swift test --filter SessionListProjectionTests`.
- Run the full `swift test` suite.
- Run `git diff --check`.
- Run `./scripts/build-app.sh 0.1.0`.
- Run `codesign --verify --deep --strict build/Aegis.app` and verify the installed `/Applications/Aegis.app` separately after replacement.
- Normal-speed feel-check: hover a compact session node. After the existing 80ms intent delay, it should expand once in 180ms with no flash, reversal, or repeated opening. Moving the pointer into the revealed detail must keep it open. Leaving the node must shrink it once in 180ms.
- Interruption check: cross the node boundary rapidly 20 times, including reversing direction during expansion and collapse. The animation must retarget smoothly from its current presentation state.
- Frame-stability check: log or inspect the `NSPanel.frame` before hovering and while the node morphs. Once the overall Aegis panel is in `.expanded`, its frame must remain byte-for-byte unchanged throughout card hover entry, exit, and reversal.
- Multi-session check: repeat on the first, middle, and last card with at least three active sessions. Siblings should move smoothly inside the fixed scroll viewport without changing the native panel frame.
- Reduced-motion check: enable System Settings → Accessibility → Display → Reduce motion. The detail reveal should use the existing gentler 120ms feedback and must not reintroduce native panel resizing.
- Performance check: the `dynamicExpandedHeight → repositionExpandedContentWindow → panel.setFrame` path must be absent, so card hover produces no per-frame native window writes.
