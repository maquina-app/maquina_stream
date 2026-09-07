# Phase 3 — Block sealing and broadcast

**Depends on:** Phase 0 (gate, currently OPEN) and Phase 2. **Blocks:** 4, 7.

## Dependency status

`docs/plan.md` lists Phase 0 as a predecessor. That dependency is real but
partial, and it is worth being precise about which half is blocked rather than
stopping the whole phase:

| Not blocked | Blocked on the Phase 0 decision |
|---|---|
| block splitter, seal pointer, block ids | caret on the open block |
| digest cache, frame coalescer, sequence | which attributes a delta frame carries for the reveal |
| append/patch frame shapes, bandwidth | the suppression flag Phase 4 wires up |

The server-side half does not care which reveal strategy won. The DoD lines that
depend on the decision are marked blocked below and are not to be ticked from
here.

## The problem

A growing buffer re-rendered per frame is quadratic. Sealing turns it into a
stream of small stable patches: everything above the seal pointer is frozen and
never re-sent, and only the open tail is patched.

## Seal lag

**Never seal block N until N+2 has opened.** Markdown reinterprets retroactively:
a paragraph becomes a setext heading when its underline arrives, a lazy
continuation joins the paragraph above it, a table's delimiter row turns the row
above into a header, and a blank line between list items re-tightens the whole
list. A block is only safe to freeze once two later blocks exist, because that
is the furthest a later line can reach back.

**The retroactive corpus is written first.** If it is written after the
splitter, it will be written to agree with the splitter.

## Block identity

Index-derived: `ms-<sid>-b<n>`. Never content-derived — idiomorph keys on `id`,
and a content-derived id makes morph delete and recreate, losing scroll
position, animation state and everything the client owns.

## Frames

| Frame | Carries |
|---|---|
| append | newly sealed blocks, whole |
| patch | the open tail block only |

Every frame carries a monotonic sequence. Frames coalesce on a configurable
50-80ms budget (`frame_budget_ms`, default 60).

## Verification

- Character-by-character replay of the fixture corpus: **once sealed, a block's
  HTML never changes**. Asserted by keeping every sealed block's digest across
  the whole replay, not by eyeballing.
- The retroactive corpus streamed a line at a time: setext headings, lazy
  continuations, table delimiter rows, list tightening.
- Bandwidth: total bytes for a 20KB message under ~2.5x message size, measured
  by the broadcast recorder named in HANDOFF.md.
- Sequence monotonic under concurrent appends.
- A stream cancelled mid-block still seals into valid HTML.

## Definition of done (from docs/plan.md)

- [ ] No sealed block is ever re-broadcast during a normal stream.
- [ ] Retroactive corpus passes in full and is in CI.
- [ ] Bandwidth ratio measured, recorded in this spec, with a test that fails on
      regression.
- [ ] Frame budget host-configurable and documented.
