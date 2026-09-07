# maquina_stream

Server-rendered streaming markdown for Rails, over Turbo, with a repair path.

A model writes markdown a token at a time. `maquina_stream` renders it to HTML
on the server, broadcasts small patches as it grows, and reconciles the browser
with the truth when frames go missing — which they do, because Action Cable
offers no delivery guarantee.

**Only rendered HTML reaches the browser.** The client never parses markdown.

## Install

```ruby
gem "maquina_stream"
```

Rails 8, Ruby 3.3+. Depends on `maquina_remend`, `commonmarker`, `nokogiri` and
`rouge`. `maquina_components` is optional — without it, components render plain
Tailwind fallbacks.

## Five minutes to a streaming message

Mount the engine so the browser can repair itself:

```ruby
# config/routes.rb
mount MaquinaStream::Engine => "/maquina_stream"
```

Tell the engine how to find a record and who may see it:

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize = ->(record, request) { record.conversation.readable_by?(request) }
end
```

Make the model streamable. The macro generates the contract methods from three
columns — the buffer you name, `stream_sequence` and `stream_status`:

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(m) { [:conversation, m.conversation_id, :messages] }
end
```

Stream into it:

```ruby
broadcaster = MaquinaStream::Broadcaster.new(message)
chat.ask(prompt) { |chunk| broadcaster.append(chunk.content.to_s) }
broadcaster.seal!
```

Render it, live or from history:

```erb
<div id="ms-msg-<%= message.maquina_stream_id %>"
     data-controller="ms-repair ms-reveal"
     data-ms-repair-manifest-url-value="<%= maquina_stream.manifest_path(sid: message.maquina_stream_id) %>"
     data-ms-repair-blocks-url-value="<%= maquina_stream.blocks_path(sid: message.maquina_stream_id) %>"
     <%= "data-ms-streaming" if message.maquina_stream_open? %>><%= MaquinaStream.render(message) %></div>
```

And start the JavaScript, which ships by importmap with no build step:

```js
import { Application } from "@hotwired/stimulus"
import { registerMaquinaStreamControllers } from "maquina_stream"

registerMaquinaStreamControllers(Application.start())
```

That is the whole integration. [Getting started](docs/getting-started.md) walks
the same path with the migration, the view and a working end-to-end run.

## What you get

Markdown in:

````markdown
## Estado

Todo **bien**. Ver [docs](https://example.com).

```ruby
puts 1
```
````

HTML out — sanitized, block-addressed, and highlighted by CSS class so a theme
switch needs no re-render (attributes elided for width):

```html
<h2 id="ms-42-b0" data-ms-element="h2" data-ms-block data-ms-block-digest="1f2c81c1fcf4af59">Estado…</h2>
<p id="ms-42-b1" data-ms-element="p" data-ms-block data-ms-block-digest="94c9fba06f14c1bc">Todo <strong>bien</strong>. Ver <a href="https://example.com" rel="noopener noreferrer">docs</a>.</p>
<div id="ms-42-b2" data-ms-code data-ms-code-lang="ruby" data-controller="ms-code" data-ms-block …>
  <pre><code><span class="nb">puts</span> <span class="mi">1</span></code></pre>
  <pre hidden data-ms-code-source>puts 1</pre>
</div>
```

Plus: copy and download on code blocks and tables, a link-safety dialog, a
word-level reveal animation, autoscroll that gets out of the reader's way,
client-rendered diagrams and math, and markdown export.

## Documentation

| Document | What it covers |
|---|---|
| [getting-started.md](docs/getting-started.md) | Install, the model, the migration, the view, the JavaScript, one message end to end |
| [configuration.md](docs/configuration.md) | Every option, its default, and how to choose |
| [streaming.md](docs/streaming.md) | The `Streamable` contract, the broadcaster, sealing, agent runs, history |
| [repair.md](docs/repair.md) | Why repair exists, the two routes, `find_stream` and `authorize` |
| [registries.md](docs/registries.md) | Fences, custom tags, element overrides |
| [javascript.md](docs/javascript.md) | The Stimulus controllers, importmap setup, controls, events |
| [security.md](docs/security.md) | The sanitizer's guarantees and limits, URL hardening |
| [deferred-renderers.md](docs/deferred-renderers.md) | Diagrams, math, writing your own |

`test/dummy` is a working host: the `Streamable` model, both seams, all three
fence strategies, the tag registry, and live pages at `/harness/chat` and
`/harness/agent` that talk to a real model.

## What it deliberately does not do

- **Deltas do not converge on their own.** Only the open tail is patched; a
  block that changes after it stops being the tail is fixed by the repair path.
- **Sealed blocks are never re-broadcast.** That is what keeps bandwidth
  tracking drift instead of message length.
- **An open fence is never highlighted**, and a client-deferred fence emits no
  payload until it closes. Expect no syntax colours and no diagram until the
  closing ``` arrives.

## License

MIT.
