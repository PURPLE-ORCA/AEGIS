# Session-card plans

| Order | Plan | Status | Dependency |
| --- | --- | --- | --- |
| 1 | [001 — Morph session card hover](001-morph-session-card-hover.md) | DONE | Compact session-card working-tree changes |
| 2 | [002 — Stabilize session-card hover motion](002-stabilize-session-card-hover.md) | DONE | Plan 001 and current title/runtime row |
| 3 | [003 — Show live agent activity in session cards](003-live-agent-activity-subtitle.md) | DONE | `dcf2422` |

Plan 003 shipped in `dcf2422`. It preserves the stable panel and card-local morph from plan 002 while replacing runtime/duplicate-title content with provider-safe activity state.

## Considered and rejected

- Rendering Codex `encrypted_content`: rejected because it is private chain-of-thought, not a user-facing summary.
- Claiming universal reasoning support: rejected because Hermes, OpenCode, AntiGravity, and hook-only Codex do not currently expose a trustworthy equivalent.
- Removing only the visible terminal pill: rejected because the card would retain a hidden, unreliable open action and misleading accessibility semantics.
