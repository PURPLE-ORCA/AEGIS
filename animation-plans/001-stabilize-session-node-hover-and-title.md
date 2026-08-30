# 001 — stabilize-session-node-hover-and-title

- **Status**: IMPLEMENTED on `codex/session-node-hover-fix`
- **Commit**: `4a5267b`
- **Severity**: HIGH
- **Category**: interruptibility, performance

Implementation commits: `8e7f441`, `c42c93c`, `7ad10c1`. Review accepted after 157-test suite, release/app bundle builds, strict codesign, focused rerun, and clean diff check. Live hover feel-check remains pending until merge and installation.

## Goal

Show the provider session title rather than the working-folder name in each compact node, and make hover expansion open or close once without oscillating when the card and native panel resize.

## Current code

`Sources/Aegis/Notch/Views/SessionMessagePresentation.swift:21-28` routes the compact title through `session.displayName`; `Session.displayName` intentionally falls back to the project folder:

```swift
static func compactTitle(for session: Session, maximumLength: Int = 80) -> String {
    SessionMessagePresentation.preview(
        session.displayName,
        fallback: session.projectName,
        maximumLength: maximumLength
    )
}
```

`Sources/Aegis/Notch/Views/SessionCardView.swift:63-78,93-112` changes the revealed subtree's hit-testing at the same time its height changes. That lets the hover target change ownership during a resize and makes transient AppKit tracking exits immediately reverse the animation:

```swift
detailContent
    .frame(height: detailPresentation.height, alignment: .top)
    .opacity(detailPresentation.opacity)
    .clipped()
    .allowsHitTesting(showsDetails)

.onHover { hovering in
    hoverExpansionTask?.cancel()
    hoverExpansionTask = nil

    if hovering {
        // delayed expansion
    } else {
        withAnimation(morphAnimation) {
            isHovering = false
        }
    }
}
```

The working tree also contains two intended, installed refinements not yet committed: `NotchMotion.panelResizeDuration` is `0.20`, and multi-provider filter buttons are 22-point circles. Preserve and include those exact deltas in the executor branch.

## Target code

### Session title

`compactTitle(for:)` must never fall back to `session.projectName` or `session.displayName`. Resolve in this order:

1. non-empty, trimmed `session.sessionTitle`;
2. non-empty, trimmed `session.firstPrompt`;
3. `"Untitled session"`.

Pass the resolved text through `SessionMessagePresentation.preview` with the existing maximum length. Update the card accessibility label to use the same compact title so VoiceOver does not announce the project name either.

### Stable hover ownership

The detail subtree is informational and the enclosing card button owns the click. Keep it permanently non-hit-testable:

```swift
.allowsHitTesting(false)
```

Add a shared exit-intent token alongside the existing entry token:

```swift
static let sessionCardHoverDelay: TimeInterval = 0.08
static let sessionCardHoverExitGrace: TimeInterval = 0.06
```

Track the latest raw hover state. On every `.onHover` event, cancel the prior task and update that raw state. Entry keeps the existing 80ms intent delay. Exit waits 60ms, then collapses only if the task was not cancelled and the latest raw state is still outside. Use the same interruptible 180ms `sessionCardMorph` animation in both directions. A transient exit/entry pair created by native tracking-area rebuilds must therefore cancel before it can reverse the card.

The 60ms grace is below the 125–200ms small-popover budget from the motion audit and adds no idle timer: a task exists only during an actual hover-boundary transition.

## Steps

1. Reapply the current working-tree refinements in the isolated branch: panel resize duration `0.20`; provider filters remain hidden below two active providers and use 22x22 `Circle` buttons with 11-point provider icons / 9-point All icon.
2. Update `SessionCardPresentation.compactTitle(for:)` to use session title, then first prompt, then `"Untitled session"`; never use the project folder.
3. Update `SessionCardView` accessibility naming to use `compactTitle(for:)`.
4. Keep `detailContent` permanently `.allowsHitTesting(false)`.
5. Add `sessionCardHoverExitGrace = 0.06` and implement one cancellable hover-intent task plus the latest raw hover state for both entry and exit.
6. Add tests proving title priority, first-prompt fallback, and no project-folder fallback. Add a small pure hover-intent policy seam only if needed for deterministic tests; do not add wall-clock sleeps to XCTest.
7. Run all verification gates and commit the implementation in focused commits.

## Scope boundary

Do not change node information architecture, detail text/model content, mascot animation, click-to-open behavior, provider sorting, filter visibility rules, fitted-content island sizing, finished-card timing, permission/question views, keep-awake behavior, or watcher parsing. Do not replace the fitted island with a fixed default height. Do not add a persistent timer or polling loop.

Do not edit the user-owned `plans/README.md`, `plans/003-live-agent-activity-subtitle.md`, or advisor-plan files.

## Verification

- `swift test --filter SessionCardPresentationTests`
- `swift test --filter SessionListProjectionTests`
- `swift test`
- `swift build -c release`
- `git diff --check`
- `./scripts/build-app.sh 0.1.0`
- `codesign --verify --deep --strict build/Aegis.app`
- Normal-speed feel-check: enter a compact card, wait 80ms, and confirm it opens exactly once in 180ms. Leave it and confirm it closes exactly once after the imperceptible 60ms exit grace.
- Interruption check: cross the boundary repeatedly and reverse direction during both opening and closing. Motion must retarget without flashing or oscillating.
- Detail ownership check: move the pointer from the compact row into the revealed text; the card must stay expanded while the whole node remains under the pointer.
- Native resize check: repeat on first, middle, and last cards with multiple sessions while the fitted island changes height. Tracking-area rebuilds must not reverse hover state.
- Reduced Motion: confirm the existing 120ms reduced animation remains and never flickers.
- Performance: after motion settles there must be no hover task, display link, or new recurring CPU work.
