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

## Bandwidth: the budget is below the floor

Measured with the broadcast recorder, 20,224 bytes of markdown, four characters
per token, one token every 25ms:

| Frame budget | Frames | Bytes sent | vs markdown | vs rendered HTML |
|---|---|---|---|---|
| 60ms (documented default) | 1,499 | 375,502 | 18.57x | 3.37x |
| 250ms | 474 | 133,837 | 6.62x | 1.20x |
| 1000ms | 120 | 109,744 | 5.43x | 0.98x |

**The rendered HTML of that message is 111,434 bytes — 5.51x the markdown.**
Sending every block exactly once, with no re-send at all, therefore costs 5.5x
the message size. `docs/plan.md` budgets "under ~2.5x message size", which is
less than half the floor: no amount of coalescing or diffing can reach it while
the thing being shipped is server-rendered HTML.

Restated against what is actually sent, the numbers are good — at a 1s budget
the broadcaster sends 0.98x the rendered document, meaning essentially nothing
is re-sent. The overhead is entirely the open tail being re-sent as it grows,
and it is the frame budget that decides how often that happens.

**Both were restated by the user on 2026-09-06:**

1. The budget is now **under 1.5x the rendered document**. Measured 1.20x.
2. The default frame budget is now **250ms**, not 60ms. The word-level reveal is
   what makes the coarser cadence look smooth, which is why Phase 0 comes first.

A third measurement, unrelated to bandwidth but found alongside it: at a 60ms
budget a single 20KB message cost **44 seconds of CPU**, because every frame
re-renders the whole buffer.

Profiling that render was worth the hour. The markdown chain — remend,
commonmarker, Nokogiri parse — is 4.3ms of a 68ms frame. ActionView is not the
cost either: caching every component render produced 755 hits and saved 6ms.
**The cost was Nokogiri traversal** — the post pass ran eighteen CSS queries per
frame over a 2,000-node document, each about 3.5ms. Collapsing it to the single
walk the class always claimed to be took a frame from **68.01ms to 20.30ms**,
and the component cache is kept for the cold path.

## Definition of done (from docs/plan.md)

- [ ] No sealed block is ever re-broadcast during a normal stream.
- [ ] Retroactive corpus passes in full and is in CI.
- [x] Bandwidth ratio measured, recorded in this spec, with a test that fails on
      regression. **The 2.5x target itself is NOT met and cannot be** - see
      above. The regression guard asserts the measured overhead above the
      rendered-HTML floor.
- [ ] Frame budget host-configurable and documented.
