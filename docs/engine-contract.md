# Engine contract

What a host application must implement to stream markdown through
`maquina_stream`. Everything here is host-facing: you should never need to read
engine internals to satisfy it. Names are fixed by `docs/api-surface.md`.

Phase 1 ships this contract, the configuration object and the routes. The
render pipeline (`Renderer`, `Document`, `Block`, `Broadcaster`, `Frame`,
`Manifest`, `Sanitizer`) arrives in Phase 2 — those classes are placeholders
today.

---

## 1. Mount the engine

```ruby
# config/routes.rb
mount MaquinaStream::Engine => "/maquina_stream"
```

Two routes come with it:

```
GET /maquina_stream/:sid/manifest        → { seq:, blocks: [[id, digest], …] }
GET /maquina_stream/:sid/blocks?ids[]=   → Turbo Stream, one morph per requested block
```

`:sid` is `#maquina_stream_id` — see the Streamable table below.

---

## 2. Make a model streamable

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
                 stream_for: ->(m) { [m.conversation, :messages] }
end
```

**The host owns persistence.** The engine reads and appends through the seven
methods below and never writes anything else.

| Method | Returns | Generated from |
|---|---|---|
| `#maquina_stream_id` | stable `String`, unique per message | `#to_param` |
| `#maquina_stream_buffer` | `String`, the raw markdown | the `buffer:` column |
| `#maquina_stream_append(text)` | appends and persists | the `buffer:` column |
| `#maquina_stream_sequence` | `Integer`, monotonic, incremented per frame | `stream_sequence` column |
| `#maquina_stream_open?` | `Boolean` | `stream_status` column, open while it equals `"open"` |
| `#maquina_stream_seal!(status: :complete)` | `:complete \| :cancelled \| :errored` | `stream_status` column |
| `#maquina_stream_target` | Turbo broadcast target | the `stream_for:` callable |

The macro generates a method only when its backing column exists. So the
minimum migration for the table above is:

```ruby
create_table :messages do |t|
  t.text    :content,         null: false, default: ""
  t.integer :stream_sequence, null: false, default: 0
  t.string  :stream_status,   null: false, default: "open"
  t.timestamps
end
```

### When your columns are named differently

Define the method yourself. A method defined in the model body always wins over
the generated one:

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable
  maquina_stream buffer: :body, stream_for: ->(m) { [m.chat, :messages] }

  def maquina_stream_sequence = frame_number
  def maquina_stream_open? = finished_at.nil?
  def maquina_stream_seal!(status: :complete) = update!(finished_at: Time.current, outcome: status)
end
```

### When the contract is unmet

Calling a method whose column is missing raises `MaquinaStream::ContractError`,
naming the method and the column it wanted:

```
Note does not satisfy MaquinaStream::Streamable: #maquina_stream_sequence
needs a `stream_sequence` column, and Note has none. Add the column,
or define #maquina_stream_sequence on Note yourself.
```

`Message.maquina_stream_contract_gaps` lists the same thing without calling
anything — useful as a one-line assertion in your own test suite:

```ruby
test "Message satisfies the maquina_stream contract" do
  assert_empty Message.maquina_stream_contract_gaps
end
```

---

## 3. The broadcast-target injection point

`stream_for:` is the injection point. It receives the record and returns
whatever `Turbo::StreamsChannel` accepts as a stream name — a record, an array,
a string:

```ruby
maquina_stream stream_for: ->(m) { [m.conversation, :messages] }
```

The engine never guesses a target and never derives one from the class name. If
`stream_for:` is missing or not callable, `#maquina_stream_target` raises rather
than falling back to a guess.

The stream name is the host's, which means the host also decides who may
subscribe. Sign or scope it exactly as you would for any other Turbo stream.

---

## 4. Authorization and lookup seams

The engine serves nothing it was not told it may serve. Both seams live in the
configuration and both are host-supplied callables:

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Current.user.messages.find_by(id: sid) }
  c.authorize   = ->(record, request) { record.conversation.readable_by?(Current.user) }
end
```

- `find_stream` resolves `:sid` to a record. Return `nil` and the engine answers
  `404`. Leave it unset and every engine request raises
  `MaquinaStream::ConfigurationError` — the engine does not go looking for a
  model on its own.
- `authorize` receives the record and the `ActionDispatch::Request`. Anything
  falsy answers `403`. **Leaving it unset denies everything**; there is no
  permissive default.

Scope the lookup rather than relying on `authorize` alone if you can — the same
advice as any Rails controller.

---

## 5. Transport seam

Solid Cable (Turbo Streams over Action Cable) is the default:

```ruby
c.transport = :turbo_streams   # default
```

The `Broadcaster` (Phase 2) emits every frame through this seam, so a host that
wants Server-Sent Events instead swaps the transport rather than patching the
render path. Frames, sequence numbers, the manifest and the repair routes are
transport-independent by construction: the repair path is plain `GET`, so a
client that lost frames recovers over HTTP no matter how frames were delivered.

---

## 6. Configuration

Every key, with its default:

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

  # Host seams (see sections 4 and 5)
  c.find_stream = nil                 # required
  c.authorize   = nil                 # required; unset denies everything
  c.transport   = :turbo_streams
end
```

`components: :maquina` uses `maquina_components` when the gem is present;
`:plain` forces the vendored Tailwind fallbacks. `maquina_components` is an
optional dependency either way.

### Registries

Hosts extend rendering without touching the engine:

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

Phase 1 stores registrations; Phase 2 consumes them. A `:client` fence emits its
payload only once the fence closes — until then the block renders a skeleton.

---

## 7. Views

Engine views resolve through normal engine view path precedence: a partial at
the same path in the host application wins. Prefer that over configuration for
anything that is purely presentational.

---

## What the engine never does

- Guess a broadcast target.
- Invent authorization, or serve a record without a host `authorize` callable.
- Write host columns other than through `#maquina_stream_append` and
  `#maquina_stream_seal!`.
- Send markdown to the browser. Only rendered, sanitized HTML crosses the wire —
  a client-deferred renderer receives one JSON payload for one leaf node, which
  is a rendering instruction, not markdown.
