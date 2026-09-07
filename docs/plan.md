# maquina_stream — implementation plan

Eight phases. Each carries tasks, verification and definition of done. Nothing advances on a phase whose DoD is unmet.

One SDD spec folder per phase: `sdd/specs/YYYY-MM-DD-maquina-stream-p<n>-<slug>/` with `progress.yml`. DoD lines below are the acceptance criteria, copied verbatim rather than rewritten.

## Dependencies

| Phase | Needs | Blocks |
|---|---|---|
| 0 | — | 3, 4, 6 |
| 1 | — | 2, 3 |
| 2 | 1 | 3, 5, 6, 7 |
| 3 | 0, 2 | 4, 7 |
| 4 | 0, 3 | 7 |
| 5 | 2 | — |
| 6 | 2, 4 | — |
| 7 | 3, 4, 5, 6 | Fragua integration |

Phases 1 and 2 can start while 0 is running. Phases 5 and 6 parallelize once 2 and 4 are done.

---

## Phase 0 — Prove the reveal survives repair
**Gate · ½–1 day · needs human judgment**

Settle the one genuine unknown before architecture is committed. The question is not whether words can animate, but whether they animate under a mid-stream snapshot morph without the message strobing.

**Tasks**
- Throwaway Rails page with a fake token emitter broadcasting frames on a timer. No engine, no abstraction.
- Strategy A: Turbo morph with id-keyed per-word spans.
- Strategy B: MutationObserver reveal controller wrapping newly inserted text client-side.
- Strategy C: block-level or CSS-masked reveal, no per-word spans.
- Force a full-message snapshot morph mid-stream in all three.
- Add the suppression flag: snapshot frames silent, delta frames animate.
- Measure DOM node count and main-thread patch time for a 20KB message.
- Check `prefers-reduced-motion` renders the final state with no animation.

**Verification**
- Screen recording of each strategy through a snapshot morph, reviewed frame by frame. No previously revealed word may re-animate.
- Node count for 20KB message under ~8,000.
- Median patch time under 8ms on a mid-range laptop; no frame over 30ms.
- Backgrounded tab 30s then restored: no animation burst.

**DoD**
- One strategy chosen, reason written in the spec.
- Specific failing behaviour of each rejected strategy documented, not just "worse".
- Suppression mechanism described concretely enough for Phase 4 to implement against.
- Reduced-motion path confirmed.

**Kill criterion:** if nothing survives a repair morph cleanly within the timebox, ship strategy C and stop. Word-level reveal is a nicety; the repair path is not. Do not let animation dictate the reconciliation design.

**Agent note:** an agent can build all three prototypes but cannot judge the recording. Do not mark this gate passed without a human review.

---

## Phase 1 — maquina_remend and the engine contract
**Shippable alone · 3–5 days**

Preprocessor as a standalone gem, zero runtime dependencies, no Rails. Alongside it, fix the engine's public surface early — the API shape constrains everything downstream.

**Tasks**
- Port the handler pipeline per `docs/remend-patterns.md`: bold, italic, bold-italic, inline code, strikethrough, links, images, block math, setext headings, comparison operators, truncated HTML tags.
- Link handling modes: placeholder protocol, and text-only.
- Context guards: nothing "fixed" inside fenced code, inline code or math.
- False-positive guards: single tilde between word chars, underscores in identifiers and LaTeX, bare currency symbols.
- Per-handler on/off options, all default on except inline math; custom handler registration.
- Fixture suite, one file per case in the pattern spec.
- Engine skeleton: `Streamable`, configuration object, mountable engine, overridable view paths.
- Broadcast-target injection point and transport seam documented.
- Dummy host app inside the engine for development and tests.
- Empirically verify the three open questions in `docs/spike-sourcepos.md`.

**Verification**
- Every fixture passes and is traceable to its numbered case.
- Idempotence across the corpus.
- No-op on well-formed input: byte-identical passthrough.
- Prefix property: for a corpus of complete documents, every truncation point parses without raising.
- Benchmark under 1ms for an 8KB buffer.

**DoD**
- Gem builds, is tagged, zero runtime dependencies.
- README documents every option with the input it repairs.
- Prefix property test runs over at least 20 real agent transcripts.
- Engine contract written down; a host can implement it without reading engine internals.
- Sourcepos runtime behaviour confirmed and the spike doc updated.

---

## Phase 2 — Render pipeline
**Pure function · 4–6 days**

Markdown in, sanitized HTML out, no request context. Same function serves live, reload, replay and export.

**Tasks**
- Chain: preprocessor → CommonMarker with source positions → Nokogiri pass → sanitizer.
- Post-pass: styling hooks per element type, table wrappers, code shells.
- Emit raw fence content alongside each code block for copy and download.
- Custom tag registry with per-tag attribute allowlists.
- Fence language registry.
- Three renderer strategies per language: server-rendered, client-deferred, passthrough.
- Client-deferred emission: JSON payload on a data attribute plus controller name, written only when the fence closes. Skeleton until then.
- Include raw source inside the payload so copy and renderer share one attribute.
- Partial override registry for element-level customization.
- Component seam: one resolver for `maquina_components` when present, vendored partial when absent. See `docs/component-scope.md`.
- Vendored components built to `maquina_components` conventions: `code_block`, `snippet`, plus `shimmer` and `source_citation` as permanent engine-owned partials.
- Rouge highlighting deferred until fence close; open fences render plain. Output renders **into** the `code_block` partial, not as bespoke markup.
- `shimmer` is the defined skeleton for open blocks and unrendered deferred payloads — no ad-hoc placeholder markup anywhere.
- `source_citation` as the reference implementation of `register_tag :source`, satisfying the registry-example DoD with a real case.
- Two theme stylesheets, light and dark, no inline colour styles.
- Sanitizer allowlist, protocol and prefix restrictions, default-origin rewriting.
- `maquina_components` when available, plain Tailwind fallbacks when not.

**Verification**
- Golden-file tests per feature, reviewed on change rather than blindly regenerated.
- XSS corpus: script tags, event handlers, `javascript:` and `data:` URLs, srcdoc, nested and entity-encoded variants.
- Live and static modes produce identical HTML apart from animation attributes.
- 500-line fence within budget; open fence performs no highlighting at all.
- Client-deferred fence emits no payload until it closes, verified character by character.
- Payload attributes survive the XSS corpus: quotes and angle brackets inside a fence never break out of the attribute.
- Dark mode switches with no re-render.

**DoD**
- Pipeline runs outside a Rails request with no stubbing.
- Every XSS corpus entry neutralized; corpus committed as a regression suite.
- Both registries documented with a working dummy-app example, including one language of each strategy. The tag registry example is `source_citation`, not a toy.
- A test asserts no engine code renders a vendored partial directly; only the resolver may.
- Vendored partials use destination `data-component` names and carry the extraction-candidate header comment.
- Live/static parity verified on the full fixture corpus.

---

## Phase 3 — Block sealing and broadcast
**Core design · 5–7 days**

Turn a growing buffer into a stream of small stable patches. Decides whether this feels fast or quadratic.

**Tasks**
- Block splitter mapping source positions to line ranges of the raw buffer.
- Seal pointer with a two-block lag.
- Stable index-derived block ids.
- Digest cache for sealed block HTML.
- Frame coalescer, configurable 50–80ms.
- Append newly sealed blocks; patch only the open tail.
- Monotonic per-message sequence on every frame.
- Caret on the open block, removed at seal.
- Buffer append API on the streamable contract, host owns persistence.

**Verification**
- Character-by-character replay of the fixture corpus: once sealed, a block's HTML never changes. Asserted, not eyeballed.
- Retroactive corpus streamed a line at a time: setext headings, lazy continuations, table delimiter rows, list tightening.
- Bandwidth: total bytes for a 20KB message under ~2.5× message size.
- Sequence monotonic under concurrent appends.
- Cancelled mid-block stream still seals into valid HTML.

**DoD**
- No sealed block is ever re-broadcast during a normal stream.
- Retroactive corpus passes in full and is in CI.
- Bandwidth ratio measured, recorded in the spec, with a test that fails on regression.
- Frame budget host-configurable and documented.

---

## Phase 4 — Repair: manifest, keyframes, convergence
**Correctness · 5–7 days**

Deltas are an optimization; correctness lives here. Keyframes ship in v1, so the digest manifest ships with them — one feature, not a feature plus an optimization.

**Tasks**
- Manifest endpoint: current sequence plus block id/digest list.
- Partial block fetch endpoint for a requested subset of ids.
- Repair controller: track sequence, detect gaps, fetch manifest, diff against DOM, fetch only differing blocks, morph silently.
- Trigger: final seal, always.
- Trigger: sequence gap.
- Trigger: cable reconnect and tab returning to visible.
- Trigger: periodic keyframe, configurable interval.
- Wire the animation suppression flag chosen in Phase 0.
- Split ownership for client-deferred blocks: payload attribute to morph, rendered output in a permanent child with stable id.
- Enumerate remaining purely client-side state with no server counterpart and mark it permanent.
- Scope morph to the in-flight message; completed messages excluded structurally.

**Verification**
- Chaos test: drop 30% of frames at random, assert final DOM matches statically rendered HTML byte for byte.
- Reconnect test: sever the cable mid-stream, restore, confirm convergence without full re-render.
- Background test: hide tab 30s mid-stream, restore, confirm convergence and no animation burst.
- Manifest payload measured at 2KB, 20KB and 100KB message sizes; effectively flat.
- Repair morph emits zero animation events, confirmed by instrumenting the reveal controller.
- Permanent subtrees survive a repair morph intact.
- A repair morph leaving a payload byte-identical triggers zero re-renders, confirmed via the value-changed callback.

**DoD**
- Every chaos-test run converges. Flakiness here is a failure, not a flake.
- Manifest payload size independent of message length, with a test asserting it.
- No strobing on repair, verified by recording as in Phase 0.
- Keyframe interval configurable, with a documented default and rationale.

---

## Phase 5 — Interaction layer
**Parallelizable · 3–4 days**

**Tasks**
- Copy code, reading the emitted raw source rather than highlighted markup.
- Download code with extension inferred from fence language.
- Copy table as markdown, CSV and TSV, reconstructed from the DOM.
- Download table as CSV or markdown.
- Image download, hidden when the image fails to load.
- Link confirmation dialog with host-supplied allowlist callback and bypass.
- Stick-to-bottom autoscroll that releases when the user scrolls and does not fight them.
- Disable all controls while streaming.
- Locale files for Spanish and English covering every control label.
- Configuration to disable any control individually or wholesale.
- Vendored `attachment` component (grid, inline, list variants) rendering from ActiveStorage attributes, not an AI SDK data shape.
- Vendored `suggestion` component: server-rendered chips, no client state.
- `snippet` shares the copy controller with `code_block`.

**Verification**
- Keyboard-only pass: every control reachable, focus visible, dialog traps and restores focus.
- Screen reader pass: meaningful accessible names, copy actions announce results.
- Clipboard verified in Chrome, Firefox and Safari, including the insecure-context fallback.
- Scrolling up mid-stream is not overridden by subsequent frames.
- Controls inert while streaming.

**DoD**
- Full keyboard and screen reader pass completed with findings fixed, not logged.
- Both locales complete, Spanish default.
- Every control individually disableable via configuration.

---

## Phase 6 — Client-deferred renderers
**One pattern · 2–4 days**

Configure the Phase 2 pattern for its first two consumers and prove a third can be added by a host without engine changes.

**Tasks**
- Base deferred-render controller: reads payload, renders on value change, lazy-imports its library only when a payload exists on the page. Unrendered state uses `shimmer`.
- Sanitize renderer output before insertion. Never assign payload or result as raw HTML.
- Diagram renderer in strict security mode, with copy source, download SVG, fullscreen, pan and zoom.
- Math renderer with trust disabled.
- Graceful error state per renderer; a broken payload never breaks the message.
- Register a third renderer in the dummy app, host-side only, to prove the registry is open.
- Decide and implement the export fallback for deferred content: source fence, alt text, or server-rendered substitute.
- Text direction handling, detected per block.
- Verify CJK renders correctly through preprocessor and parser.

**Verification**
- Rendered output survives a forced repair morph without re-rendering or flickering.
- Streaming a deferred fence character by character never shows an error state before it closes.
- Injection corpus inside payloads: script content, event handlers and foreign objects stripped before insertion, verified per renderer rather than assumed from the server sanitizer.
- Invalid payloads degrade to a readable fallback with the message intact.
- A page with no deferred content loads no renderer libraries. Confirm in the network panel.
- The third renderer works with no engine changes, host configuration only.
- Mixed-direction and CJK fixtures render correctly, including inside emphasis and code.

**DoD**
- Rendered output survives repair, verified as an automated test.
- Renderer-side sanitization has its own regression suite, independent of the server's.
- Heavy libraries load lazily, never on pages that don't need them.
- A host can add a renderer using only the documented registry, demonstrated in the dummy app.
- Export fallback decided, implemented once, applied to every deferred renderer.

---

## Phase 7 — History, hardening and 0.1
**Release · 4–6 days**

**Tasks**
- History pagination through Turbo Frames, loading upward on scroll.
- Completed messages frozen, fragment-cached by digest, structurally excluded from morph scope.
- Explicit states for cancelled, errored and timed-out streams, including replay behaviour.
- Whole-message markdown export from the buffer, applying the Phase 6 fallback for deferred content. Read Vercel's `messagesToMarkdown` for the formatter-hook shape first.
- Review `MaquinaStream::VENDORED_COMPONENTS`: confirm each is still a candidate, and that the seam's fallback branch is the only thing blocking extraction.
- Multi-tab behaviour reviewed: two tabs on one stream converge without redundant work.
- Dummy app demonstrating every feature, usable as the documentation example.
- README and integration guide: streamable contract, configuration, registries, view overrides.
- CI matrix across supported Ruby and Rails versions.
- Tag 0.1 and open the Fragua integration branch against it.

**Verification**
- A 500-message session loads within budget; memory flat while scrolling history.
- Replaying a completed session produces HTML identical to the live end state.
- A cancelled stream replays into the partial state it ended in, with clear visual indication.
- A fresh developer can integrate the engine into a bare Rails app using only the README.
- Fragua integration exercises the contract without engine changes. If it needs changes, the contract was wrong.

**DoD**
- Long-session load and memory figures recorded in the spec.
- Replay parity asserted in CI, not checked once by hand.
- Documentation complete enough that the dummy app is the only example needed.
- 0.1 tagged; Fragua consumes the released gem, not a path reference.
