# Registries

Three registries let a host change what the pipeline renders without touching
engine internals. All three are process-global and are read during the render
post-pass. Names and signatures come from `docs/api-surface.md` and are fixed.

The dummy app registers all of them in
`test/dummy/config/initializers/maquina_stream.rb`, and
`test/maquina_stream/registries_example_test.rb` exercises that registration
through the full pipeline — markdown in, rendered HTML out. Copy from there.

## Fence registry

```ruby
MaquinaStream.register_fence "ruby",    strategy: :server
MaquinaStream.register_fence "text",    strategy: :passthrough
MaquinaStream.register_fence "mermaid", strategy: :client,
  controller: "ms-diagram",
  payload: ->(source, info) { { source: source, info: info } }
```

| Strategy | Open fence | Closed fence |
|---|---|---|
| `:server` | code shell, **no highlighting** | Rouge-highlighted, into the `code_block` component |
| `:client` | `shimmer` skeleton, **no payload** | payload attribute plus controller name |
| `:passthrough` | plain `<pre><code>` | plain `<pre><code>` |

An unregistered language falls back to `:server`.

Two rules the pipeline enforces rather than trusts:

- **An open fence is never highlighted.** The work would be thrown away on the
  next frame, and it is the difference between a 500-line fence fitting in the
  frame budget and not.
- **A client fence emits no payload until it closes.** A payload emitted early
  hands the client half a diagram to draw.

The client-deferred block splits ownership, per the DOM contract: the payload
attribute is server state and belongs to morph; the output element is client
state, is `data-turbo-permanent`, and belongs to the controller.

## Tag registry

The reference case, and a real one: a model citing its sources.

```ruby
MaquinaStream.register_tag :source,
  attributes: %w[id href title],
  partial: "maquina_stream/components/source_citation",
  literal_content: false
```

Given `<source id="3" href="https://example.com/a" title="Un artículo"></source>`,
the post-pass replaces that node with the partial, passing **only** the
registered attributes as locals. An attribute the registration does not list —
`onclick`, say — never reaches the partial at all; it is gone before the
sanitizer is even asked.

`literal_content: true` passes the tag's text rather than its inner HTML.

Registered attribute names become partial locals, so they must match the locals
the partial declares.

**An unregistered tag does not survive — its content does.** The sanitizer
*unwraps* an element it does not know: the tag goes, its children stay. See
"App-meaning tags" below for what that means for `<thinking>` and friends.

**`register_tag` is a single-node facility.** The post-pass replaces the tag's
node with the partial and hands it that node's inner HTML. A tag wrapped around
one inline run — the `<source>` case above — is exactly what it is for. A tag
wrapped around several paragraphs is not: see below.

## Element registry

```ruby
MaquinaStream.register_element :h2, partial: "my/headings/h2"
```

Replaces every `<h2>` with that partial, receiving `content:` (the inner HTML)
and `node:` (the Nokogiri node). Elements the host does not override still carry
`data-ms-element="h2"` as a styling hook.

## App-meaning tags

Models emit XML-ish tags that mean something to the application rather than to
markdown: `<thinking>`, `<answer>`, `<tool_call>`, `<citation>`. CommonMark has
never heard of any of them, so the line that opens one starts an **HTML block**
and everything under it is raw HTML as far as the parser is concerned. What
happens next is decided by the sanitizer and the splitter.

`test/maquina_stream/app_tags_test.rb` holds every claim on this page as an
assertion, and `test/fixtures/markdown/app_tags.md` is in the corpus the
pipeline properties run over.

### Unregistered

The tag is unwrapped by the sanitizer, and its content is kept. Text that was
directly under the tag comes back as a **bare text node at the top level** of
the fragment — not inside any element.

Document wraps orphan text (and any inline element stranded the same way) into a
`<p>` before splitting, so it lands in a block of its own. Before that wrapping
existed, `children.select(&:element?)` dropped it and the first paragraph under
a `<thinking>` tag silently vanished from the message. The property that pins
it — the concatenated text of the blocks equals the text of the whole sanitized
document — lives in `pipeline_properties_test.rb` and is asserted over the whole
corpus, not over that one tag.

Mid-stream, with the tag open and `</thinking>` not yet sent:

- maquina_remend's `html_tags` handler removes only a tag whose `>` has not
  arrived yet (`"text <thinki"` → `"text"`). It does **not** balance an element
  that opened and has not closed, and it does not need to.
- The content survives every frame, because the sanitizer unwraps the tag
  whether it closed or not. The unwrapped shape is the same before and after the
  close.
- Nothing flickers. Closing the tag changes no block above it, so a sealed block
  is never rewritten — the seal lag is not even called on here.

An orphan block wrapped this way is a real block with an id and a digest, and it
morphs and repairs like any other. Its id comes from the first free index at or
after its position: the post-pass numbers the top-level elements it sees, and a
wrapper was not one of them. Ids stay unique, which is what idiomorph needs;
they are not always in ascending order.

### Registered, and block level

**`register_tag` really only works for inline or single-node tags.** Registering
`:thinking` and pointing it at a partial does not give you a block-level
container:

1. Everything inside the tag becomes **one** block. The partial receives one
   node's inner HTML, so four paragraphs of reasoning render as one block, and
   there is no arrangement of the registration that changes that.
2. Worse, the partial receives content that came **after** the closing tag.
   CommonMark emits `</thinking>` inside a paragraph — `…</thinking></p>` — so
   the HTML5 parser never closes the element and parses the rest of the message
   inside it. The paragraph after the tag ends up in the partial.
3. That merged node is the last block, so it can never be far enough from the
   tail to seal. The whole remainder of the message is re-sent on every frame.

Sealing is not violated by this — the merge only ever grows the tail, and a
block that sealed before the tag opened is never rewritten — but the collapse
leaves so few blocks that the seal lag holds almost all of the message open.

Until that is fixed, a host that wants a block-level container around several
blocks should leave the tag unregistered and style the blocks, or strip the tag
before the buffer reaches the renderer.

## What the registries never do

They do not let a host inject raw HTML into the document. Whatever a partial
renders still passes through the sanitizer, which is the last pass and has no
exceptions — see `docs/sanitizer.md`.
