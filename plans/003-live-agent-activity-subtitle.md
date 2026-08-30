# 003 — Show live agent activity in session cards

- **Status**: IMPLEMENTED
- **Written against**: d996e35
- **Implementation commit**: dcf2422
- **Severity**: MEDIUM
- **Category**: correctness, privacy, UI information architecture, tests

## Goal

Replace the compact card's raw runtime with the existing animated status chip, replace the duplicate title inside the expanded region with a clean live activity subtitle, and remove the non-working open-session affordance and click action.

The subtitle may display a provider-authored reasoning **summary** when one is explicitly available. It must never expose, decrypt, infer, or render private chain-of-thought.

## Audit result

This is feasible with an important provider boundary:

- Codex Desktop transcripts emit `response_item` records whose payload type is `reasoning`. Some records contain a `summary` array with `summary_text` entries. These short provider-authored summaries are suitable for a glanceable activity subtitle.
- The same records also contain `encrypted_content`. That value is private model reasoning and is strictly out of scope. Production code must not read that key.
- Hermes Desktop currently exposes user, assistant, and tool rows through `messages`; it does not expose an equivalent reasoning-summary field.
- Hook-driven Codex CLI, Hermes CLI, OpenCode, and AntiGravity currently normalize status/tool events but do not provide a trustworthy reasoning summary.

Therefore the product language and model field must be `activitySummary`, not `reasoning`. Codex can show the latest explicit summary. Every provider gets a deterministic fallback from canonical state: `Thinking…`, `Using <tool>`, `Needs approval`, or `Error`.

## Current code

`Sources/Aegis/Notch/Views/SessionCardView.swift:125-139` renders the session name plus a standalone runtime in the compact row:

```swift
Text(MarkdownText.inline(SessionCardPresentation.preview(for: session)))
    .frame(maxWidth: .infinity, alignment: .leading)

if isActive {
    TimelineView(.periodic(from: .now, by: 1.0)) { context in
        runtimeLabel(at: context.date)
    }
} else {
    runtimeLabel(at: Date())
}
```

`Sources/Aegis/Notch/Views/SessionCardView.swift:158-196` repeats the title inside the expanded region, shows another duration, then renders the animated status and terminal/open pills below it:

```swift
HStack(spacing: 8) {
    Text(session.displayName)
    // effort, model, and session.durationText
}

if let prompt = session.lastUserMessage ?? session.firstPrompt {
    Text(prompt)
}

HStack(spacing: 7) {
    statusPill
    Spacer(minLength: 6)
    terminalPill
}
```

The card is also an outer `Button` whose action calls `TerminalJumper.jump(to:)`, and its accessibility copy promises the same open action (`SessionCardView.swift:56-88`). Removing only the visible `Open Codex`/`Open Hermes` pill would leave a hidden, unreliable click action behind.

`Sources/Aegis/Codex/CodexDesktopSessionWatcher.swift:370-388` parses tool response items but ignores `reasoning` response items entirely. `BridgeMessage` and `Session` have no activity-summary field.

## Target behavior

### Compact card

Use this hierarchy:

```text
[mascot]  Session name                         [animated status chip]
```

- Keep the session name as the primary compact label.
- Move the existing `statusPill` into the trailing compact-row slot.
- Remove `runtimeLabel`, `SessionCardPresentation.runtimeText`, and the compact `TimelineView`.
- Simplify `statusPill` to the animated icon plus status text only. Do not retain the elapsed timer inside the chip; it is the timing display being replaced.
- Preserve the existing animated sparkle, theme colors, truncation, and Reduce Motion behavior.

### Expanded card

Use this hierarchy:

```text
Current activity summary or canonical fallback
Latest user prompt
Optional model / effort metadata
Idle conversation preview when applicable
```

- Remove the duplicate `session.displayName` heading and `session.durationText` from the expanded region.
- Render a one- or two-line activity subtitle in their place.
- When `session.status == .thinking`, prefer a non-empty `session.activitySummary`; otherwise show `Thinking…`.
- When `session.status == .toolUse`, always show `Using <currentTool>` ahead of any older summary so the subtitle cannot describe stale reasoning while a tool is running.
- Use canonical fallbacks for approval and error states.
- Flatten whitespace, strip code fences, cap the subtitle to a small UI-safe length (160 characters is sufficient), and use the existing `SessionMessagePresentation.preview` convention.
- Keep model and effort as quiet metadata if present, but do not reintroduce the title or either runtime.

### Open action

- Replace the outer `Button` in `SessionCardView` with inert card content.
- Delete `terminalPill` from `SessionCardView`.
- Remove the open-action accessibility label/hint and give the card a descriptive session/activity accessibility value instead.
- Do not delete `TerminalJumper`: mirrored questions and other app flows still use it.
- Update `README.md` so it no longer says session cards are clickable. Keep the documented decision/question jump behavior accurate.

## Data path

### 1. Add an explicitly safe field

In `Sources/Aegis/IPC/MessageProtocol.swift`, add optional `activitySummary` / `activity_summary` support to `BridgeMessage`.

In `Sources/Aegis/Session/Session.swift`, add:

```swift
var activitySummary: String?
```

Document it as an optional provider-authored user-facing summary, never raw or encrypted reasoning.

### 2. Parse only Codex summary text

In `CodexDesktopSessionWatcher.ingest`, add a `response_item` branch for `itemType == "reasoning"`:

1. Read only `payload["summary"]` as an array of dictionaries.
2. Keep entries whose `type` is exactly `summary_text` and whose trimmed `text` is non-empty.
3. Use the latest non-empty entry as the current activity summary.
4. Emit a canonical `BridgeMessage` with `hookEvent: "ActivityUpdate"`, `activitySummary`, `source: "codex"`, and the current model/cwd.
5. Do not read or reference `payload["encrypted_content"]` in production code.
6. Emit nothing when the summary array is absent or empty.

Do not attempt to synthesize summaries from tool inputs, assistant output, prompts, encrypted content, or provider logs.

### 3. Store ephemeral activity without lifecycle side effects

In `SessionStore`:

- Add `ActivityUpdate` to `canonicalEvents`.
- Before session creation/resurrection, ignore an `ActivityUpdate` if the session does not already exist or is not currently `.thinking`/`.toolUse`. A late summary must not create a phantom card or revive a completed turn.
- Handle `ActivityUpdate` by updating only `session.activitySummary` and the normal activity timestamp. Do not change status, current tool, active-start time, sounds, permissions, questions, or session-start/end events.
- Clear `activitySummary` on `UserPromptSubmit`, `Stop`, and `SessionEnd` so summaries never leak across turns.
- It is acceptable to retain a summary while a tool runs, but presentation must prioritize `Using <tool>` until `PostToolUse` returns the session to `.thinking`.

Do not add a `SessionEvent` for activity updates; this is visual state and must not produce sounds or metrics events.

### 4. Centralize presentation

In `SessionMessagePresentation.swift`, add a pure helper such as:

```swift
static func activitySubtitle(for session: Session, maximumLength: Int = 160) -> String
```

Use it from both the expanded subtitle and accessibility value. Keep status/tool precedence testable outside SwiftUI.

## Tests

Follow the existing XCTest patterns and temporary JSONL fixtures.

### `Tests/AegisTests/CodexDesktopSessionWatcherTests.swift`

Add coverage that:

- an appended `response_item.reasoning` record with `summary_text` emits exactly one `ActivityUpdate` carrying the summary;
- multiple summary entries choose the latest non-empty `summary_text`;
- a record containing only encrypted content emits no activity update;
- the test fixture may include a sentinel `encrypted_content`, but assertions must prove the sentinel never appears in any emitted `BridgeMessage` field.

### `Tests/AegisTests/SessionStorePublicationTests.swift`

Add coverage that:

- `ActivityUpdate` changes only `activitySummary` and publishes once;
- it preserves `.thinking` and `.toolUse` state;
- it produces no `SessionEvent`;
- a missing, idle, completed, or ended session ignores a late update and is not created/resurrected;
- a new prompt and Stop clear the prior summary.

### `Tests/AegisTests/SessionCardPresentationTests.swift`

Replace the runtime-format test with activity-subtitle tests:

- thinking prefers a non-empty provider summary;
- thinking without a summary falls back to `Thinking…`;
- tool use overrides a stale summary with `Using <tool>`;
- multiline/markdown-like summary text is flattened and capped;
- waiting and error states use canonical fallbacks.

## Files in scope

- `Sources/Aegis/Codex/CodexDesktopSessionWatcher.swift`
- `Sources/Aegis/IPC/MessageProtocol.swift`
- `Sources/Aegis/Session/Session.swift`
- `Sources/Aegis/Session/SessionStore.swift`
- `Sources/Aegis/Notch/Views/SessionMessagePresentation.swift`
- `Sources/Aegis/Notch/Views/SessionCardView.swift`
- `Tests/AegisTests/CodexDesktopSessionWatcherTests.swift`
- `Tests/AegisTests/SessionStorePublicationTests.swift`
- `Tests/AegisTests/SessionCardPresentationTests.swift`
- `README.md`
- `plans/003-live-agent-activity-subtitle.md` and `plans/README.md` for status updates

## Scope boundary

Do not:

- decrypt, display, log, persist, or transmit private chain-of-thought;
- claim reasoning-summary support for Hermes, OpenCode, AntiGravity, or hook-only Codex;
- generate an activity summary with another model or add a network call;
- infer intent from tool arguments or assistant output;
- change the card hover animation, fixed 320pt expanded panel, sorting, provider groups, sound system, session lifecycle thresholds, permission/question UI, or finished reply UI;
- remove `TerminalJumper` or break the explicit jump used by mirrored questions;
- add a new user-facing label such as `REASONING` or `ACTIVITY`; the subtitle should read naturally without an eyebrow.

## Verification

Run, in order:

```bash
swift test --filter CodexDesktopSessionWatcherTests
swift test --filter SessionStorePublicationTests
swift test --filter SessionCardPresentationTests
swift test
git diff --check
./scripts/build-app.sh 0.1.0
codesign --verify --deep --strict build/Aegis.app
```

Expected automated result: all focused tests and the full suite pass, the release bundle builds, and strict code-sign verification succeeds.

Live checks after safe replacement of `/Applications/Aegis.app`:

1. Codex Desktop session with a non-empty summary: compact card shows the session title plus animated status chip; expanded card shows the latest summary in one or two lines.
2. Codex record with empty summary: expanded card falls back to `Thinking…` without flicker or blank space.
3. Tool transition: subtitle immediately becomes `Using <tool>` and returns to the latest/new activity summary after tool completion.
4. Hermes and another hook-only provider: status/tool fallback remains useful and no reasoning claim appears.
5. Confirm no runtime appears in compact or expanded card.
6. Confirm there is no `Open Codex`, `Open Hermes`, terminal pill, clickable card action, or open-action accessibility hint.
7. Confirm hover expand/shrink remains smooth and the native panel frame stays fixed.

## Escape hatches

- If current Codex transcript fixtures no longer contain `summary_text`, stop and report schema drift instead of reading encrypted content.
- If a provider exposes only raw chain-of-thought, do not integrate it; keep the canonical fallback.
- If removing the outer card `Button` breaks hover tracking, preserve the inert layout and move hover handling to a non-interactive container; do not restore the unreliable open action.
- If `ActivityUpdate` can arrive after Stop in real ordering, the store guard must drop it; do not revive the session.

## Maintenance note

Future providers may populate `activity_summary` only when they offer an explicit user-facing summary field. Each integration needs a fixture proving that the chosen upstream field is a summary rather than raw reasoning. The UI must remain useful when `activitySummary == nil`.
