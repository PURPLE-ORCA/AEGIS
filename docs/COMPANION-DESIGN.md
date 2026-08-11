# Ambient Companion Contract

Mysa is CAESURA-ISLAND's optional MSW ambient sentinel. It communicates useful local agent state without creating a second productivity system.

## Product boundary

The companion must never gain hunger, XP, token feeding, streak loss, loot, rankings, leaderboards, collectible pressure, or forced daily-return mechanics. Its state remains local and derives only from the sessions CAESURA-ISLAND already observes.

## State grammar

| State | Meaning | Motion | Reduced motion |
| --- | --- | --- | --- |
| Idle | No live agent work | Still | Still |
| Observing | A session exists but is not actively working | Slow review posture | First review frame |
| Working | One or more agents are thinking or using tools | Focused processing loop | First working frame |
| Attention | A permission or question needs the owner | Expectant waiting loop | Amber first frame |
| Success | A turn completed | Brief restrained wave, then settle | Green first frame, then settle |
| Failure | A live session reports an error | Composed failure loop without panic | Red first frame |

Priority is attention, failure, working, transient success, observing, then idle. Success is brief and never interrupts actionable or active work.

## Runtime limits

- No animation timer while idle, hidden, occluded, in Low Power Mode, or when Reduce Motion is enabled.
- Animation uses bounded sprite rows; there is no physics loop.
- The panel is transparent, non-activating, shadowless, draggable, and constrained to a visible display.
- The user controls visibility, scale, and whether the companion follows active desktop spaces.
