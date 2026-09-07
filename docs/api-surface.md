# API surface

Fixed before implementation so phases don't invent divergent names. Two gems in the `maquina_` ecosystem:

- **`maquina_remend`** — preprocessor, zero dependencies, no Rails.
- **`maquina_stream`** — Rails engine. Depends on `maquina_remend`, `commonmarker`, `nokogiri`, `rouge`.

Changing anything here after Phase 3 is a breaking change. Changing it during Phases 1–2 is free — flag it rather than working around it.

---

## maquina_remend

```ruby
MaquinaRemend.call(markdown, **options) # => String
```

Pure function. Idempotent. Returns the input unchanged when it is already well formed.

```ruby
MaquinaRemend.call(md,
  bold: true, italic: true, bold_italic: true,
  inline_code: true, strikethrough: true,
  links: true, images: true,
  block_math: true, inline_math: false,   # inline off: ambiguous with currency
  setext_headings: true,
  comparison_operators: true,
  html_tags: true,
  single_tilde: true,
  link_mode: :protocol,                    # :protocol | :text_only
  handlers: []                             # extra handlers, run after built-ins
)
```

Custom handler contract:

```ruby
class MyHandler
  def call(text, context) # context: MaquinaRemend::Context
    text
  end
end
```

`Context` exposes `#in_code_fence?`, `#in_inline_code?`, `#in_math?`, `#open_fence_info`.

---

## maquina_stream — configuration

```ruby
MaquinaStream.configure do |c|
  c.frame_budget_ms      = 60
  c.keyframe_interval_ms = 4_000
  c.seal_lag             = 2          # never seal block N until N+seal_lag opens
  c.locale               = :es
  c.components           = :maquina   # :maquina | :plain
  c.themes               = { light: "github", dark: "github_dark" }

  c.default_origin         = nil
  c.allowed_protocols      = %w[http https mailto]
  c.allowed_link_prefixes  = ["*"]
  c.allowed_image_prefixes = ["*"]
  c.allow_data_images      = true

  c.controls = {
    code:  { copy: true, download: true },
    table: { copy: true, download: true, fullscreen: true },
    image: { download: true },
    link_safety: true
  }

  # Host seams. Added in Phase 1: the repair routes cannot be written without
  # them, and this document said only "the engine calls a configured callable".
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize   = ->(record, request) { record.conversation.readable_by?(request) }
  c.transport   = :turbo_streams      # Solid Cable underneath; seam for SSE
end
```

`find_stream` and `authorize` have no defaults. An unset `authorize` denies:
authorization is the host's, and an engine that guesses is an engine that leaks.

### Registries

```ruby
MaquinaStream.register_element :h2, partial: "my/headings/h2"

MaquinaStream.register_tag :source,
  attributes: %w[id],
  partial: "my/tags/source",
  literal_content: false

MaquinaStream.register_fence "ruby",    strategy: :server
MaquinaStream.register_fence "unknown", strategy: :passthrough
MaquinaStream.register_fence "mermaid",
  strategy: :client,
  controller: "ms-diagram",
  payload: ->(source, info) { { source: source, info: info } }
```

`:client` emits the payload only once the fence closes. Until then the block renders a skeleton.

---

## Streamable contract

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable
  maquina_stream buffer: :content,
                 stream_for: ->(m) { [m.conversation, :messages] }
end
```

Host must satisfy. The macro generates each of these when the column it reads
exists — `buffer:` names the buffer column, and the other two are conventions
this document fixes in Phase 1:

| Generated method | Column |
|---|---|
| `#maquina_stream_buffer`, `#maquina_stream_append` | the column named by `buffer:` |
| `#maquina_stream_sequence` | `stream_sequence` |
| `#maquina_stream_open?`, `#maquina_stream_seal!` | `stream_status`, holding `open` / `complete` / `cancelled` / `errored` |

A method whose column is missing raises `MaquinaStream::ContractError` naming the
method, the column and the class. A method the host defines in the model body
always wins over the generated one.

| Method | Returns |
|---|---|
| `#maquina_stream_id` | stable `String`, unique per message |
| `#maquina_stream_buffer` | `String`, the raw markdown |
| `#maquina_stream_append(text)` | appends and persists |
| `#maquina_stream_sequence` | `Integer`, monotonic, incremented per frame |
| `#maquina_stream_open?` | `Boolean` |
| `#maquina_stream_seal!(status: :complete)` | the status symbol it sealed with |
| `#maquina_stream_advance` | `Integer` — the next sequence number. **Phase 2 adds this**: `maquina_stream_sequence` is documented as "incremented per frame", but the Broadcaster cannot write host state directly without contradicting "host owns persistence". |
| `#maquina_stream_target` | Turbo broadcast target |

---

## Core objects

| Object | Responsibility |
|---|---|
| `MaquinaStream::Renderer` | `.call(markdown, mode:, config:) → SafeBuffer`. Pure; no request context. `mode:` is `:streaming` or `:static`. |
| `MaquinaStream::Document` | `.new(markdown, config:)` → `#blocks`, `#sealed_blocks`, `#open_block` |
| `MaquinaStream::Block` | `#id #index #markdown #html #digest #sealed? #line_range` |
| `MaquinaStream::Broadcaster` | frame coalescing, Turbo Stream emission |
| `MaquinaStream::Frame` | `#seq #appends #patch` |
| `MaquinaStream::Manifest` | `#seq #blocks` → `[[id, digest], …]` |
| `MaquinaStream::Sanitizer` | allowlist + URL hardening, last pass before output |

---

## DOM contract

Naming: `ms-` prefix throughout. `<sid>` is `maquina_stream_id`.

```html
<div id="ms-msg-<sid>"
     data-controller="ms-stream ms-repair ms-reveal ms-autoscroll"
     data-ms-stream-seq-value="0"
     data-ms-repair-manifest-url-value="/maquina_stream/<sid>/manifest"
     data-ms-repair-blocks-url-value="/maquina_stream/<sid>/blocks"
     data-ms-repair-interval-value="4000">

  <div id="ms-<sid>-b0" data-ms-block-index="0"
       data-ms-block-digest="a91c…" data-ms-block-state="sealed">…</div>

  <div id="ms-<sid>-b1" data-ms-block-index="1"
       data-ms-block-state="open">…</div>
</div>
```

Block ids are **index-derived, never content-derived**. Idiomorph keys on `id`; a content-derived id makes morph delete and recreate.

### Code block

```html
<div data-ms-code data-ms-code-lang="ruby">
  <pre><code>…highlighted…</code></pre>
  <script type="text/plain" data-ms-code-source>…raw source…</script>
</div>
```

### Client-deferred block

```html
<div data-controller="ms-diagram"
     data-ms-diagram-payload-value='{"source":"graph TD…","info":"mermaid"}'>
  <div data-ms-diagram-target="output"
       id="ms-<sid>-b7-out" data-turbo-permanent></div>
</div>
```

Payload attribute is server state, owned by morph. Output element is client state, owned by the controller. An unchanged payload after a repair morph fires no value-changed callback and triggers no re-render.

---

## Stimulus controllers

| Identifier | Job |
|---|---|
| `ms-stream` | tracks sequence, applies delta frames |
| `ms-repair` | manifest diff, block fetch, silent morph, keyframe timer |
| `ms-reveal` | word reveal; exposes `suppress()` / `resume()` for repair |
| `ms-deferred` | base class: lazy import, render on payload change, sanitize output |
| `ms-diagram`, `ms-math` | extend `ms-deferred` |
| `ms-code` | copy, download |
| `ms-table` | copy and download as markdown, CSV, TSV; fullscreen |
| `ms-link-safety` | confirmation dialog, allowlist callback |
| `ms-autoscroll` | stick to bottom, release on user scroll |

---

## Component seam

Components destined for `maquina_components` are vendored inside the engine for now. Everything renders through one resolver so extraction is mechanical. See `docs/component-scope.md`.

```ruby
# helper, available in engine views
component(:code_block, lang: "ruby", source: raw, css_classes: "…")
```

Resolution order:

1. `maquina_components` partial, when the gem is present and defines it
2. vendored partial at `app/views/maquina_stream/components/_<name>.html.erb`

Vendored partials follow `maquina_components` conventions exactly:

```erb
<%# EXTRACTION CANDIDATE → maquina_components. See docs/component-scope.md %>
<%# locals: (variant: :default, size: :md, css_classes: "", **html_options) %>
```

- `data-component` values use the **destination** name — `code-block`, not `ms-code-block`
- symbol defaults, `css_classes:` not `class:`, always `**html_options`, data attributes merged never overwritten
- one stylesheet per component, loaded only when the vendored fallback is active

`MaquinaStream::VENDORED_COMPONENTS` lists extraction candidates. A test asserts no engine code renders a vendored partial directly — only the resolver may.

| Name | Status |
|---|---|
| `attachment` | vendored, extract later |
| `code_block` | vendored, extract later |
| `suggestion` | vendored, extract later |
| `snippet` | vendored, extract later |
| `shimmer` | engine-owned, permanent |
| `source_citation` | engine-owned, permanent |

---

## Routes

```
GET /maquina_stream/:sid/manifest        → { seq:, blocks: [[id, digest], …] }
GET /maquina_stream/:sid/blocks?ids[]=   → Turbo Stream, morph per requested block
```

CRUD-shaped: `MaquinaStream::ManifestsController#show` and
`MaquinaStream::BlocksController#index`. The engine looks the message up through
`config.find_stream`, and refuses to serve it unless `config.authorize` returns
truthy.

Authorization is the host's. The engine calls a configured callable and never assumes it can serve a message.
