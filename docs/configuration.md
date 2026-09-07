# Configuration

Configure once, from an initializer. Configuration is global and read on every
render, so changing it mid-stream changes what later frames of an open message
look like.

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize = ->(record, request) { record.conversation.readable_by?(request) }
end
```

Everything else has a working default. `MaquinaStream.config` returns the same
object outside a `configure` block.

## Host seams

| Option | Default | What it does |
|---|---|---|
| `find_stream` | `nil` | Callable turning a stream id into a record. Unset, every repair request raises `ConfigurationError`. |
| `authorize` | `nil` | Callable deciding whether a request may see a record. **Unset, every repair request is refused.** |
| `transport` | `:turbo_streams` | Which transport `Broadcaster`'s default emitter uses. `:turbo_streams` is the only value the engine ships; the seam exists so SSE is possible without the broadcaster knowing about it. |

`find_stream` raises when unset and `authorize` denies when unset, and the
difference is deliberate: a silent `nil` from the finder would look like a
missing record rather than a missing seam, while denial is always the safe
answer to "may this request see this?".

See [repair.md](repair.md) for both in context.

## Streaming cadence

| Option | Default | What it does |
|---|---|---|
| `frame_budget_ms` | `100` | How long appends coalesce before one frame goes out. |
| `seal_lag` | `2` | How many blocks must open after a block before it may freeze. |
| `keyframe_interval_ms` | `4000` | How often the client reconciles its DOM against the manifest. |
| `manifest_window` | `50` | How many recent sealed blocks a manifest carries in full. |

### Choosing `frame_budget_ms`

This is the one number worth thinking about, because the right value depends on
how *your* model delivers text. Coalescing only saves bytes when appends arrive
faster than the budget: below that, raising it merges frames and cuts bandwidth;
above it, raising it does nothing but add latency.

Measured on a 20KB message, as a multiple of the size of the rendered document.
Find the row that matches your model and pick a column you can live with:

| How your text arrives | 60ms | 100ms | 150ms | 250ms |
|---|---|---|---|---|
| token by token — 4 chars every 25ms | 3.03x | 2.34x | 1.65x | 1.08x |
| batched — 40 chars every 200ms | 1.07x | 1.07x | 1.07x | 0.89x |
| step by step — 2000 chars every second | 1.17x | 1.17x | 1.17x | 1.17x |

**If your provider streams token by token, raise this.** At the default you pay
2.34x; at 250ms you pay 1.08x, and the word-level reveal animation covers the
coarser cadence so the reader does not see the difference.

**If your text arrives in batches or whole steps, leave it alone.** Raising it
buys nothing at those cadences, and at 250ms it starts silently merging two
steps into one frame — which costs the per-step feedback that is the reason to
stream a step at all.

### `seal_lag`

A block freezes only once `seal_lag` later blocks exist. Markdown reinterprets
backwards — a paragraph becomes a heading when its underline arrives — so a
block that is still near the tail is still moving. Lower it and you freeze
blocks that were about to change; raise it and more blocks stay in the patch set
of every frame.

The seal pointer additionally stops at a block holding an unresolved link
reference, because `[docs]` cannot be rendered until `[docs]:` arrives.

With the default, a four-block message has two sealed blocks and two open ones:

```ruby
doc = MaquinaStream::Document.new("# Uno\n\nDos\n\nTres\n\nCuatro\n",
  config: MaquinaStream.config, sid: "42", mode: :streaming)

doc.blocks.map { |b| [b.id, b.sealed?] }
# => [["ms-42-b0", true], ["ms-42-b1", true], ["ms-42-b2", false], ["ms-42-b3", false]]
```

### `keyframe_interval_ms` and `manifest_window`

The keyframe is the periodic "am I still right?" check. Lower it and drift is
corrected sooner, at the cost of one small request per interval per open
message. The request is small because the manifest is windowed: the last
`manifest_window` sealed blocks in full, plus one rollup digest covering
everything older, so the payload is bounded by the window rather than by the
message.

## Presentation

| Option | Default | What it does |
|---|---|---|
| `locale` | `:es` | Fallback locale for the engine's own labels when `I18n.locale` is unset. Spanish and English both ship complete. |
| `components` | `:maquina` | `:maquina` renders through `maquina_components` when that gem is installed and defines a component; `:plain` forces the engine's own Tailwind fallback even when the gem is present. |
| `themes` | `{light: "github.light", dark: "github.dark"}` | Rouge theme names for the two generated highlighting stylesheets. |
| `controls` | every control on | Which interactive affordances render. |

### Themes

Highlighting emits CSS classes and never inline colour, so switching to dark
mode is a stylesheet concern and needs no re-render — which matters, because a
re-render mid-stream would mean re-broadcasting sealed blocks to change a
colour.

Two stylesheets ship generated. Load both; they are scoped so only one applies:

```erb
<%= stylesheet_link_tag "maquina_stream/themes/light" %>
<%= stylesheet_link_tag "maquina_stream/themes/dark" %>
```

```css
/* every rule is scoped to a code block and to one scheme */
:root:not([data-theme="dark"]) [data-ms-code] … { }
[data-theme="dark"]            [data-ms-code] … { }
```

Changing `config.themes` means regenerating them:

```sh
bundle exec rake maquina_stream:themes
```

Names are Rouge's own — the registry has `github.light` and `github.dark`, not
`github_dark`. An unknown name raises `MaquinaStream::Themes::UnknownTheme`
rather than falling back silently.

### Controls

Every control, and its group:

| Group | Controls |
|---|---|
| `code` | `copy`, `download` |
| `table` | `copy`, `download`, `fullscreen` |
| `image` | `download` |
| `attachment` | `download`, `remove` |
| `suggestion` | `enabled` |
| `link_safety` | a single boolean, not a group |

An assigned hash merges onto the defaults one level deep, so you name only what
you are changing:

```ruby
c.controls = {code: {download: false}}   # copy stays on
c.controls = false                       # everything off
c.controls = true                        # everything back on
```

```ruby
config.control?(:code, :copy)      # => true
config.control?(:code, :download)  # => false, after the first line above
config.control?(:code)             # => true, while any code control remains
```

Turning a group off removes the buttons the renderer emits. A table with no
controls left loses its control bar and its `data-controller` too — a controller
with nothing to drive is cost on every frame:

```html
<!-- controls = false -->
<div data-ms-table><table data-ms-element="table">…</table></div>
```

Controls you render yourself should carry `data-ms-control`, or they stay
clickable while the message is still streaming. See [javascript.md](javascript.md).

## URL hardening

Read by the sanitizer, which is the last pass before any HTML leaves the server.
Every one of these loosens or tightens what a **model** may put in an `href` or
a `src`, and model output is prompt-injectable.

| Option | Default | What it does |
|---|---|---|
| `default_origin` | `nil` | Base for resolving relative URLs. `nil` leaves a relative URL relative. |
| `allowed_protocols` | `%w[http https mailto]` | The only schemes that survive. |
| `allowed_link_prefixes` | `["*"]` | `"*"` allows any destination. A list of prefixes strips the `href` off every link not starting with one; the text stays. |
| `allowed_image_prefixes` | `["*"]` | Same, for images. An image whose `src` does not survive is removed entirely. |
| `allow_data_images` | `true` | Whether `data:` image URLs survive. Only base64 rasters ever do. |

```ruby
c.allowed_link_prefixes = ["https://example.com/"]
```

```html
<!-- in  --> <a href="https://evil.test/x">a</a> <a href="https://example.com/ok">b</a>
<!-- out --> <a>a</a> <a href="https://example.com/ok" rel="noopener noreferrer">b</a>
```

```ruby
c.default_origin = "https://app.example.com"
```

```html
<!-- in  --> <a href="/docs">d</a>
<!-- out --> <a href="https://app.example.com/docs" rel="noopener noreferrer">d</a>
```

`data:image/svg+xml` is refused whatever `allow_data_images` is set to: it is a
scriptable document wearing an image's MIME type. Full detail in
[security.md](security.md).

## Resetting

```ruby
MaquinaStream.reset_configuration!
```

For tests. Called in production it loses your `find_stream` and `authorize`
seams, and every repair request after it is refused.
