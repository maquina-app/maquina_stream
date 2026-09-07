# Phase 0 — tasks

Commit at task boundaries, not at the phase boundary. Task numbers are commit scopes.

| # | Task | Done when |
|---|---|---|
| 1 | `ms-spike` app skeleton: route, controller, layout, fixture text (short + 20KB) | `/spike/a` renders a static message from the fixture |
| 2 | `TokenEmitter` PORO + broadcast: monotonic `seq`, delta frames, configurable interval | words arrive on the page over Action Cable |
| 3 | Snapshot frames: whole-message morph mid-stream, marked as snapshot | forced snapshot visibly replaces the message subtree |
| 4 | Frame dropping (`--drop`) so snapshots repair real divergence | dropped deltas leave a gap the snapshot closes |
| 5 | Instrumentation panel + **animation event counter** | re-animation count, node count, patch median/max, frames, `seq` all live |
| 6 | Strategy A — id-keyed per-word spans, morph | runs end to end through a snapshot |
| 7 | Strategy B — MutationObserver reveal controller | runs end to end through a snapshot |
| 8 | Strategy C — block-level / CSS-masked reveal | runs end to end through a snapshot |
| 9 | Reveal suppression flag: snapshot frames silent, delta frames animate | toggling it changes the re-animation count |
| 10 | 20KB measurement run: node count, patch median/max | numbers recorded in `progress.yml` |
| 11 | `prefers-reduced-motion`: final state, no animation | asserted with the media feature emulated |
| 12 | Backgrounded tab 30s → restored: no animation burst | asserted with the counter across a visibility change |
| 13 | Human review: recordings of all three through a snapshot | **human only.** Decision written into `spec.md`, then copied under Phase 0 in `docs/plan.md` |

Tasks 1–12 are agent work. Task 13 is the gate and cannot be closed by an agent.
