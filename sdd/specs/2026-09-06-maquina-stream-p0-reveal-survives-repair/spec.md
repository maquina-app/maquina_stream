# Phase 0 — Prove the reveal survives repair

**Status:** gate open. Requires human judgment; an agent may not close it.
**Spike repo:** `ms-spike` (throwaway, sibling of the gem repos, deleted after the decision).
**Blocks:** Phases 3, 4, 6.

## The question

Not "can words animate". They can. The question is whether they animate **through a
mid-stream snapshot morph** without the message strobing — previously revealed words
re-playing their entrance animation when a repair morph re-inserts text that was
already on screen.

`docs/design.md` states the collision plainly: *"Morph and reveal collide. A repair
morph re-inserting revealed text would re-animate the message. Snapshot morphs are
silent; only delta frames animate."* Phase 0 exists to find out which reveal strategy
can actually honour that sentence, and to describe the suppression mechanism concretely
enough that Phase 4 can implement against it.

## Non-goals

- No engine, no `maquina_stream` code, no abstraction. Frames come from a fake emitter.
- No markdown. The emitter streams pre-tokenised words; `maquina_remend` is Phase 1.
- No repair protocol. The snapshot here is a whole-message morph, deliberately the
  worst case. The manifest/block-diff optimisation is Phase 4's job and would *hide*
  the problem this phase is trying to see.

## Harness

A single page per strategy at `/spike/a`, `/spike/b`, `/spike/c`, all driven by the
same emitter and the same instrumentation, so the only variable is the reveal.

**Emitter** — `TokenEmitter`, a PORO. Streams a fixture message word by word over
Action Cable (async adapter, dev, same process) on a configurable interval. Per run it
can be told to:

- `--interval` frame period in ms (default 50)
- `--snapshot-at` frame indexes that force a **full-message snapshot morph** mid-stream
- `--drop` percentage of delta frames to silently discard (a preview of Phase 4's frame
  dropper; here it exists only to make a snapshot arrive with real divergence to repair)
- `--size` fixture size, with a 20KB fixture for the node-count and patch-time budgets

Every frame carries a monotonic `seq`. Delta frames append; snapshot frames replace the
whole message. Snapshot frames are marked so the reveal can be suppressed for them —
that flag is the thing under test, not a detail.

**Instrumentation** — an on-page panel, live, so the human review is watching numbers
move rather than trusting a summary:

- **re-animation count** — animations that started on a word already marked revealed.
  This is the strobe, counted. It must be 0.
- DOM node count for the message subtree
- patch time per frame: median and max, measured around the morph
- frames sent / applied / dropped, and current `seq`

The re-animation counter is the **animation event counter** named in `HANDOFF.md` as a
verification harness. It is what turns "no strobing" from an opinion into an assertion.

## Strategies

**A — server-rendered per-word spans, id-keyed, morphed.** Each word is
`<span id="…-w<n>" data-revealed>`; ids are index-derived, per the morph constraint in
`CLAUDE.md`. Reveal is CSS animation on insertion. Snapshot morph re-sends every span;
survival depends on morph matching ids and on the revealed marker surviving the morph.

**B — MutationObserver reveal controller.** Server sends plain text; the client wraps
newly inserted text nodes and animates them. Server output is clean; the client owns
the wrapping, which means it also owns the risk of re-wrapping morph-inserted text.

**C — block-level / CSS-masked reveal, no per-word spans.** No per-word DOM at all;
a mask or gradient advances over the block. Cheapest node count by far, coarsest
animation. This is also the **kill criterion**: if nothing survives the morph cleanly
inside the timebox, C ships and the phase ends.

## Verification (copied from `docs/plan.md`, verbatim)

- Screen recording of each strategy through a snapshot morph, reviewed frame by frame.
  No previously revealed word may re-animate.
- Node count for 20KB message under ~8,000.
- Median patch time under 8ms on a mid-range laptop; no frame over 30ms.
- Backgrounded tab 30s then restored: no animation burst.

Plus `prefers-reduced-motion`: final state rendered, no animation.

The first line needs a human. The rest are machine-checkable and are asserted by the
panel, with a headless driver run recording the numbers.

## Definition of done (from `docs/plan.md`)

- [ ] One strategy chosen, reason written in this spec.
- [ ] Specific failing behaviour of each rejected strategy documented, not just "worse".
- [ ] Suppression mechanism described concretely enough for Phase 4 to implement against.
- [ ] Reduced-motion path confirmed.

## Decision

> **Unfilled. This section is written by a human after watching the recordings.**
> Phases 3, 4 and 6 read it. If it stays empty, three later sessions will each invent
> their own answer, which is the failure this section exists to prevent. Once written,
> the decision is copied as a line under Phase 0 in `docs/plan.md`.

**Chosen strategy:** —

**Why:** —

**Rejected — A, specific failing behaviour:** —

**Rejected — B, specific failing behaviour:** —

**Suppression mechanism, for Phase 4:** —

**Reduced motion:** —
