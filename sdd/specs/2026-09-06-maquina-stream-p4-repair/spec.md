# Phase 4 — Repair: manifest, keyframes, convergence

**Depends on:** Phase 0 (gate OPEN) and Phase 3. **Blocks:** 7.

## Working assumption about Phase 0

Phase 0's gate needs a human to watch the recordings, and it has not been
closed. This phase is built anyway, against **strategy C** as the working
assumption, for reasons that are measurements rather than preferences:

| 20KB message | DOM nodes | patch median | patch max | old text re-animated |
|---|---|---|---|---|
| A id-keyed spans | 10,103 ✗ | 0.4ms | 248ms ✗ | 0 |
| B MutationObserver | 10,101 ✗ | 42.7ms ✗ | 147.8ms ✗ | 0 |
| C masked block | **1** | 1.1ms | 2.0ms | 0 |
| budget | ~8,000 | < 8ms | < 30ms | 0 |

A and B each blow budgets the plan sets; C is the only strategy inside all of
them, and `docs/plan.md` says outright: *"if nothing survives a repair morph
cleanly within the timebox, ship strategy C and stop."*

**This does not close the gate.** The suppression seam below is built so that
any of the three still works, so a human decision that contradicts this costs a
configuration change rather than a rewrite.

## Deltas are an optimization; correctness lives here

Phase 3 deliberately does not broadcast every change: it patches the open tail
only, and a block that reinterprets behind the seal pointer is left wrong on the
client until repair. This phase is what makes that safe.

## Manifest

A snapshot is not HTML — it is a list of block digests:

```json
{ "seq": 412, "blocks": [["ms-m8f21-b0","a91c…"], ["ms-m8f21-b1","4fe2…"]] }
```

A few hundred bytes regardless of message size. The client diffs it against its
own DOM, asks for the blocks that differ, and morphs only those. Repair cost
tracks drift, not message length, which is what makes periodic keyframes
affordable at all.

## Triggers

1. **Final seal** — always. This is what makes intra-stream drift cosmetic.
2. **Sequence gap** — a frame never arrived.
3. **Reconnect, or the tab becoming visible again.**
4. **Periodic keyframe** — `keyframe_interval_ms`, default 4s.

## Suppression

A repair morph must not animate. The seam is one pair of calls on the reveal
controller — `suppress()` before the morph, `resume()` after — dispatched as
events so it works for whichever strategy Phase 0 picks. Strategy C needs no
suppression at all (a snapshot does not change text length, so the mask never
restarts), which is a further argument for it; the seam exists anyway because
the decision is not mine.

## Verification

- **Chaos test**: drop 30% of frames at random, assert the final DOM matches
  statically rendered HTML byte for byte. Every run converges — flakiness here
  is a failure, not a flake.
- Manifest payload measured at 2KB, 20KB and 100KB: effectively flat.
- A repair morph leaving a payload byte-identical triggers zero re-renders.
- Permanent subtrees survive a repair morph intact.

## Definition of done (from docs/plan.md)

- [ ] Every chaos-test run converges.
- [ ] Manifest payload size independent of message length, with a test.
- [ ] No strobing on repair, verified by recording as in Phase 0. **Needs the
      Phase 0 human review; the counter is built and asserts 0.**
- [ ] Keyframe interval configurable, with a documented default and rationale.
