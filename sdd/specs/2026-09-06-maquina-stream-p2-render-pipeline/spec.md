# Phase 2 — Render pipeline

**Depends on:** Phase 1. **Blocks:** 3, 5, 6, 7.

## The function

```ruby
MaquinaStream::Renderer.call(markdown, mode: :streaming, config: MaquinaStream.config) # => SafeBuffer
```

Pure. No request, no controller, no stubbing — if it starts needing request
context that is a design error, not a plumbing problem. The same function serves
the live stream, a page reload, a replay and an export; `mode:` changes only
whether animation attributes are emitted.

## The chain

    maquina_remend  →  CommonMarker (sourcepos)  →  Nokogiri post-pass  →  Sanitizer

1. **Preprocess.** The buffer is a streaming tail; repair it before parsing.
2. **Parse** with `render: { sourcepos: true }` and `parse: { sourcepos_chars: true }`.
   Phase 3 slices the raw buffer by those line ranges; Phase 2's job is to not
   lose them.
3. **Post-pass.** Walk the document once: styling hooks per element type, table
   wrappers, code shells, custom tags, fence strategies, element partial
   overrides. Everything that needs the tree happens in this one walk.
4. **Sanitize.** Allowlist, protocol and prefix restrictions, default-origin
   rewriting. Last pass before output, always — never assign model output as raw
   HTML.

## Fence strategies

| Strategy | Open fence | Closed fence |
|---|---|---|
| `:server` | plain text in the code shell, no highlighting | Rouge-highlighted, into the `code_block` partial |
| `:client` | `shimmer` skeleton, **no payload attribute** | one JSON payload for one leaf node, plus the controller name |
| `:passthrough` | plain text | plain text |

Highlighting an open fence is wasted work on every frame, and a client payload
emitted before the fence closes is a payload the client renders half of. Both
are verified character by character, not by reasoning.

## Component seam

One resolver. `maquina_components` when present and defining the component, the
vendored partial otherwise. No engine code renders a vendored partial directly —
a test asserts it. Vendored partials use **destination** `data-component` names
(`code-block`, never `ms-code-block`) and carry the extraction-candidate header.

## Verification

- Golden files per feature, reviewed on change rather than regenerated blindly.
- XSS corpus committed as a regression suite: script tags, event handlers,
  `javascript:` and `data:` URLs, srcdoc, nested and entity-encoded variants,
  and quotes/angle brackets inside a fence trying to break out of the payload
  attribute.
- Live and static modes byte-identical apart from animation attributes.
- 500-line fence within budget; an open fence performs no highlighting at all.
- Dark mode switches with no re-render (two stylesheets, no inline colour).

## Definition of done (from docs/plan.md)

- [ ] Pipeline runs outside a Rails request with no stubbing.
- [ ] Every XSS corpus entry neutralized; corpus committed as a regression suite.
- [ ] Both registries documented with a working dummy-app example, including one
      language of each strategy. The tag registry example is `source_citation`.
- [ ] A test asserts no engine code renders a vendored partial directly.
- [ ] Vendored partials use destination names and the extraction header.
- [ ] Live/static parity verified on the full fixture corpus.
