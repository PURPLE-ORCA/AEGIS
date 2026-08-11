# 001 — Smooth session card hover expansion

- **Status**: DONE
- **Severity**: MEDIUM
- **Category**: easing, interruptibility, accessibility, cohesion

## Goal

Make compact session cards reveal their detailed content smoothly on hover, without flicker, double-rendered content, or a lagging notch window.

## Root cause

The first pass animated the same height change twice. SwiftUI interpolated the card height and reported every intermediate measurement, while `NotchWindowController` cancelled and restarted a separate panel-frame tween for each report. The compact and detailed card trees also crossfaded while matched geometry rendered a second mascot, which made the transition look unstable.

## Implementation

1. Keep the compact mascot and message row mounted for the entire interaction.
2. Insert details with an asymmetric transition: fade them in, then remove them immediately on collapse so layout space cannot linger.
3. Use a 200ms strong ease-out curve for expansion, a snappier 160ms strong ease-out for collapse, and a gentler 120ms reduced-motion variant.
4. Let the AppKit panel follow SwiftUI's already-interpolated measured height directly instead of starting another animation.
5. Preserve the existing 320ms display-link animation for full notch state changes.

## Scope boundary

Do not change click-to-open behavior, status colors, mascot artwork, provider section motion, finished-popup motion, permission/question views, or the session-card information architecture.

## Verification

- `swift test`
- `git diff --check`
- `./scripts/build-app.sh`
- `codesign --verify --deep --strict build/CAESURA-ISLAND.app`
- Relaunch the workspace-built app and verify repeated hover expansion, reversal, and collapse.

## Execution notes

- Corrected on 2026-08-11 after live feedback exposed the competing height animations.
- Persistent compact content removes the double-rendered mascot/message flash.
- Direct panel tracking removes the per-frame animation restart loop.
- `swift test`: 39 passed.
- Release bundle build and strict codesign verification passed.
- Native runtime QA confirmed the compact resting state in the workspace-built app.
- Follow-up closing fix removes the outgoing opacity transition without feeding measured geometry back into SwiftUI state; this keeps collapse immediate and avoids constraint-cycle crashes during live session removal.
