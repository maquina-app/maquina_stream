# maquina_stream — design analysis

Agent-readable conversion of the design document. Companion: `docs/plan.md`, `docs/api-surface.md`.

## Verdict

Replicating Streamdown and remend in Rails is viable, and for an app that holds the model connection server-side it is structurally simpler than the React original. Streamdown spends most of its complexity on React reconciliation and client-side memoization to solve a problem we avoid by not sending markdown to the browser.

We lose free reconciliation. We gain one rendering path shared by live streaming, reload, replay and export, plus server-side sanitization.

## What we're replicating

**remend** is small and valuable: a zero-dependency string preprocessor that closes unterminated syntax before parsing. Full pattern list in `docs/remend-patterns.md`.

**Streamdown** decomposes into four layers:

1. **Correctness** — remend plus incomplete-fence handling. A pure function. *Port it.*
2. **Incremental rendering** — block splitting and memoization so completed content stays stable. *Redesign it;* this is where React earns its keep.
3. **Presentation** — highlighting, diagrams, math, typography, direction. *Straightforward.*
4. **Interaction** — copy, download, export, fullscreen, link safety, caret, autoscroll. *Trivial Stimulus.*

## Decisions (locked)

| Question | Decision |
|---|---|
| Does the token stream reach the browser? | **No.** Only rendered HTML. The raw buffer stays server-side as the source of truth; every view is a pure function of it. |
| Fragua-internal or general? | **General engine**, `maquina_stream`. Fragua is its first consumer, not its owner. |
| Morph or append-only? | **Hybrid.** Deltas for speed, snapshots for truth. Morph scope bounded to the in-flight message. |
| Periodic keyframes in v1? | **Yes.** Therefore the block digest manifest ships with them, not later. |
| Renderers Ruby can't do? | **Client-deferred:** JSON payload on a data attribute plus a Stimulus controller. One pattern for math, diagrams and anything a host registers. |

## Render pipeline

```
buffer → maquina_remend → CommonMarker (sourcepos) → Nokogiri pass → sanitize → HTML
```

One function, string in, safe HTML out, no request context. The Nokogiri pass does what `components`, `allowedTags` and custom renderers do upstream: styling hooks, table wrappers, code shells, custom tag substitution, fence dispatch.

Source positions arrive as `data-sourcepos` attributes directly on rendered elements — see `docs/spike-sourcepos.md`.

### Three renderer strategies

| Strategy | Ships | Example |
|---|---|---|
| Server-rendered | final HTML | code fences via Rouge |
| Client-deferred | opaque JSON payload + controller name | diagrams, math, chart specs |
| Passthrough | plain preformatted text | unknown languages |

Client-deferred does not contradict the HTML-only decision. That decision is "no markdown parsing on the client", not "no data crosses the wire". What ships is a rendering instruction for one leaf node.

Three properties follow:

- **Payload presence is the completeness signal.** Emitted only when the fence closes; no separate open-fence flag needs to reach the controller.
- **It makes morph easier.** Payload attribute is server state, owned by morph. Rendered output is client state in a permanent child, owned by the controller. An unchanged payload fires no value-changed callback and triggers no re-render.
- **It generalizes.** Hosts register new renderers without engine changes or Ruby.

**Security:** the payload is model output and therefore prompt-injectable. Never assign it as raw HTML. Diagrams render in strict mode with the resulting SVG sanitized before insertion; math renders with trust disabled. Server-side attribute escaping protects the attribute boundary only.

**Cost:** replay is no longer self-sufficient. Export, print and email need a fallback — source fence, alt text, or a server-rendered substitute. Decide once for all deferred renderers. Keep the source string inside the same payload the copy button reads.

### Highlighting

Rouge replaces Shiki. Token classes rather than inline styles, so two theme stylesheets give real dark-mode switching with no re-render. An open fence renders as plain preformatted text; highlighting runs only when the fence closes.

### Copy actions

HTML-only means "copy code" cannot reconstruct the source from highlighted markup. Emit the raw content alongside the block. Table copy-as-markdown rebuilds from the DOM. Copy-whole-message needs the buffer.

## Block sealing

Re-broadcasting the whole message per frame is quadratic. The Hotwire analogue of block memoization:

- Split the buffer into top-level blocks via source positions.
- Sealed blocks are appended once, cached by digest, never touched again.
- Only the open tail block is patched.

**Trap:** block boundaries move backwards. A paragraph followed by `---` becomes a setext heading; a lazy continuation merges upward; a table delimiter row reinterprets its header. React reparses everything and lets reconciliation absorb it; we cannot.

**Rule:** never seal block N until block N+2 has opened. A one-block lag removes the entire class of bug.

**Frame budget:** coalesce to 50–80ms. Parsing is not the bottleneck; the cable round trip and DOM patch are. Throttling also improves the reveal animation by grouping arrivals into perceptible units.

## Delta and repair

Action Cable gives no delivery guarantee, no ordering guarantee, no gap detection. Without a repair path the client diverges silently.

**Three problems, only one is reconciliation:**

**A. Long session on first load** — pagination, not repair. Completed messages are immutable: frozen, digest-keyed, fragment-cached, lazily loaded upward. Morph never touches them. Consequence: morph scope is exactly one message, so reconciliation cost is independent of session length.

**B. Drift during a live stream** — every frame carries a monotonic sequence. Snapshots fire on four triggers:

1. **Final seal**, always. Makes all intra-stream drift cosmetic and self-correcting.
2. **Gap detected** in the sequence.
3. **Reconnect or tab visible again.**
4. **Periodic keyframe.**

**C. Snapshot cost on long messages** — the snapshot is not HTML, it is a block digest manifest:

```json
{ "seq": 412, "blocks": [["m8f21-b0","a91c…"], ["m8f21-b1","4fe2…"]] }
```

A few hundred bytes regardless of message size. The client diffs, requests only differing blocks, morphs those. Repair cost tracks drift, not length. This is what makes periodic keyframes affordable.

**Invariant:** deltas are an optimization; correctness comes from snapshots. A correctness bug fixed inside the delta path is fixed in the wrong place.

## Morph constraints

- **Stable ids are mandatory.** Index-derived, never content-derived. A content-derived id makes morph delete and recreate, losing scroll position, animation state and client-side mutations.
- **Client state needs an owner.** The client-deferred pattern handles most of this structurally. What remains is a short enumerable list: scroll offsets, expansion toggles.
- **Morph and reveal collide.** A repair morph re-inserting revealed text would re-animate the message. Revealed spans get marked; the reveal controller exposes suppression. **Snapshot morphs are silent; only delta frames animate.**

## Engine contract

| Surface | Contract |
|---|---|
| Streamable | Host mixes in a concern or supplies an adapter. Host owns persistence. |
| Broadcast target | Signed stream name from the host. Engine never guesses a target or invents authorization. |
| Configuration | Tags, fence renderers, partial overrides, theme, budgets, sanitizer allowlists. |
| Components | `maquina_components` when present, vendored partial when absent, resolved through one seam. A small set is vendored inside the engine for now and extracted later — see `docs/component-scope.md`. |
| Transport | Solid Cable by default, behind a seam so SSE is possible. |
| Views | Overridable via normal engine view path precedence. |

Signatures in `docs/api-surface.md`.

## The hard parts

1. **Word-level reveal without strobing.** Three candidate strategies; settled by Phase 0 spike, not by argument. Acceptance criterion is surviving a mid-stream repair morph, not the animation itself.
2. **Retroactive block reinterpretation.** Handled by the seal lag, but needs fixtures that stream setext headings, lazy continuations and tables one line at a time.
3. **Repair cost discipline.** Manifest and keyframe ship together or neither ships. A keyframe without a manifest becomes the bandwidth problem it was introduced to prevent.

## Still open

- **Keyframe interval** — fixed, or scaled by message size? With the manifest in place, fixed is probably fine.
- **Export fallback for client-deferred content** — source fence, alt text, or server-rendered substitute. One answer covers every deferred renderer. Decided in Phase 6.
- **Multi-tab behaviour** — two tabs repair independently. Correct, but confirm it is not wasteful.
- **Cancelled and errored streams** — sealing, replay and visual state. Cheaper to design now than retrofit.
