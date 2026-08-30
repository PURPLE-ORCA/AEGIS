# Animation plans

| Order | Plan | Status | Dependency |
| --- | --- | --- | --- |
| 1 | [001 — Stabilize session-node hover and title](001-stabilize-session-node-hover-and-title.md) | IMPLEMENTED | `8e7f441`, `c42c93c`, `7ad10c1` |
| 2 | [002 — Snap finished-card collapse](002-snap-finished-card-collapse.md) | IMPLEMENTED | `031813f` |
| 3 | [003 — Restore brief collapse motion](003-restore-brief-collapse-motion.md) | SUPERSEDED | `3afa07a`, `27e6c47`; replaced by plan 004 |
| 4 | [004 — Restore instant finished-card collapse](004-restore-instant-finished-card-collapse.md) | IMPLEMENTED | `7d7c0ee`; opening/visibility follow-up `27c3077` |

These plans are isolated from the user-owned `plans/` directory. The current policy closes finished cards atomically, opens them in 120 ms, and keeps them visible for five seconds.
