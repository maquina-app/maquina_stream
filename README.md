# maquina_stream

Server-rendered streaming markdown for Rails, over Turbo, with a repair path.

A model writes markdown a token at a time. This renders it on the server, sends
small patches as it grows, and reconciles the browser with the truth when frames
go missing — which they do, because Action Cable offers no delivery guarantee.

**Only rendered HTML reaches the browser.** The client never parses markdown.

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
                 stream_for: ->(m) { [m.conversation, :messages] }
end
```

```ruby
broadcaster = MaquinaStream::Broadcaster.new(message)
model.stream { |token| broadcaster.append(token) }
broadcaster.seal!
```

That is the whole integration. Everything below is detail.

## Install

```ruby
gem "maquina_stream"
```

Rails 8, Ruby 3.3+. Depends on `maquina_remend`, `commonmarker`, `nokogiri` and
`rouge`. `maquina_components` is optional — without it, components render plain
Tailwind fallbacks.

Mount the engine for the repair endpoints:

```ruby
mount MaquinaStream::Engine => "/maquina_stream"
```

## The host owns three things

The engine resolves nothing and authorizes nothing on its own.

```ruby
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize   = ->(record, request) { record.conversation.readable_by?(request) }
end
```

**With no `authorize` configured, every repair request is refused.** That is
deliberate: an engine that guesses is an engine that leaks.

The third is persistence. `Streamable` generates the contract methods when your
column names match (`stream_sequence`, `stream_status`, and whatever you named
in `buffer:`); a missing column raises an error naming the method, the column
and the class. Full contract in `docs/engine-contract.md`.

## JavaScript

Importmap, no build step. The engine appends its own pins.

```js
import { Application } from "@hotwired/stimulus"
import { registerMaquinaStreamControllers } from "maquina_stream"

registerMaquinaStreamControllers(Application.start())
```

## Configuration

Every documented key, with its default, is in `docs/api-surface.md`. The three
worth knowing about:

| Key | Default | Why it is what it is |
|---|---|---|
| `frame_budget_ms` | `250` | Frames coalesce inside this. At 60ms a 20KB message costs 3.37x the rendered document in bandwidth; at 250ms, 1.20x. The word-level reveal covers the coarser cadence. |
| `seal_lag` | `2` | A block freezes only once two later blocks exist, because markdown reinterprets backwards. The pointer additionally stops at a block with an unresolved link reference. |
| `keyframe_interval_ms` | `4000` | How often the client reconciles against the manifest, which is a few hundred bytes whatever the message weighs. |

## History

A sealed message is immutable, so render it through the cache:

```erb
<%= MaquinaStream.render(message) %>
```

Cached by buffer digest once sealed, rendered live while open, and a new key if
a host edits it. A 20KB message costs 95ms to render and 0.05ms to serve from
cache; a page of fifty goes from 4.7s to 2.4ms.

Pagination is the host's — which messages, in what order — and the dummy app
shows the pattern at `/history`: a lazy Turbo Frame at the top of each page
loads the page above it on scroll, so history grows upward without a
pagination bar.

## Documentation

| Document | What it covers |
|---|---|
| `docs/engine-contract.md` | What a host implements, without reading engine internals |
| `docs/registries.md` | Fences, custom tags, element overrides |
| `docs/interaction.md` | The four controllers and the markup they bind to |
| `docs/deferred-renderers.md` | Diagrams, math, and adding a third renderer host-side |
| `docs/sanitizer.md` | What survives, what is dropped, and the known holes |
| `docs/component-scope.md` | Which components are vendored and how they extract |
| `docs/agent-runs.md` | Streaming a tool-call run: one record per step, or one buffer |
| `docs/design.md` | Why the architecture is what it is |

`test/dummy` is a working host: the Streamable model, both seams, all three
fence strategies, the tag registry, and a browser harness at `/harness`.

## Measured, not asserted

| | |
|---|---|
| Render | 20.3ms per frame for a 20KB message |
| Bandwidth | 1.25x the rendered document (budget 1.5x) |
| Manifest | 1.5-1.8KB for messages from 2KB to 100KB |
| History | 500 messages rendered in 387ms, 0.77ms each; a sealed message serves from cache in 0.05ms |
| Preprocessor | 0.32ms for an 8KB buffer |
| Convergence | 30% of frames dropped, 8 seeds, every run converges |

## What it deliberately does not do

- **Deltas do not converge on their own.** Only the open tail is patched; a
  block that changes after it stops being the tail is fixed by the repair path.
  Correctness lives there, and the delta path is an optimization.
- **Sealed blocks are never re-broadcast.** That is what keeps bandwidth
  tracking drift instead of message length.
- **An open fence is never highlighted**, and a client-deferred fence emits no
  payload until it closes. Both would be work thrown away on the next frame.

## License

MIT.
