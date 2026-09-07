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

**An unregistered tag does not survive.** The sanitizer drops it.

## Element registry

```ruby
MaquinaStream.register_element :h2, partial: "my/headings/h2"
```

Replaces every `<h2>` with that partial, receiving `content:` (the inner HTML)
and `node:` (the Nokogiri node). Elements the host does not override still carry
`data-ms-element="h2"` as a styling hook.

## What the registries never do

They do not let a host inject raw HTML into the document. Whatever a partial
renders still passes through the sanitizer, which is the last pass and has no
exceptions — see `docs/sanitizer.md`.
