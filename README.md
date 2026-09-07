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
Tailwind fallbacks. Turbo is required: repair applies Turbo Stream morphs, and
with `window.Turbo` undefined every repair fails silently.

```sh
bin/rails generate maquina_stream:install
bin/rails generate maquina_stream:streamable Message
bin/rails db:migrate
```

The first wires the engine into the app — the initializer, the mount, the
importmap pins, the Stimulus registration, the stylesheets. The second is per
model, because a host may have several: the migration carrying the contract
columns, and the `include` plus macro in the model. Both are idempotent and
neither overwrites a file; a host missing an ingredient is told what to paste
rather than left with a silent no-op.

## Two seams the generators will not guess

**`authorize`**, in `config/initializers/maquina_stream.rb`. It is generated as
a stub that denies everything, which is the safe failure and a broken feature
both — the browser can never repair a message until you replace it. Guessing a
host's authorization is how an engine leaks other people's messages:

```ruby
c.authorize = ->(record, request) { record.conversation.member?(request.session[:user_id]) }
```

**`stream_for:`**, in the model. Who may subscribe to a stream is your question,
not the engine's:

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(record) { [:conversation, record.conversation_id, :messages] }
end
```

## Streaming a message

Feed the broadcaster and seal exactly once:

```ruby
broadcaster = MaquinaStream::Broadcaster.new(message)
chat.ask(prompt) { |chunk| broadcaster.append(chunk.content.to_s) }
broadcaster.seal!
```

Render it, live or from history. The engine appends block HTML into
`#ms-msg-<sid>` and never creates that element — the wrapper is yours:

```erb
<div id="ms-msg-<%= message.maquina_stream_id %>"
     data-controller="ms-repair ms-reveal"
     data-ms-repair-manifest-url-value="<%= maquina_stream.manifest_path(sid: message.maquina_stream_id) %>"
     data-ms-repair-blocks-url-value="<%= maquina_stream.blocks_path(sid: message.maquina_stream_id) %>"
     <%= "data-ms-streaming" if message.maquina_stream_open? %>><%= MaquinaStream.render(message) %></div>
```

That is the whole integration. [Getting started](docs/getting-started.md) walks
the same path with a working end-to-end run, and lists every step the
generators take for hosts that would rather do them by hand.

## What you get

Markdown in:

````markdown
## Status

All **good**. See [docs](https://example.com).

```ruby
puts 1
```
````

HTML out — sanitized, block-addressed, and highlighted by CSS class so a theme
switch needs no re-render (attributes elided for width):

```html
<h2 id="ms-42-b0" data-ms-element="h2" data-ms-block data-ms-block-digest="fa59d158d6fc403e">Status…</h2>
<p id="ms-42-b1" data-ms-element="p" data-ms-block data-ms-block-digest="c39b9098233d53d5">All <strong>good</strong>. See <a href="https://example.com" rel="noopener noreferrer">docs</a>.</p>
<div id="ms-42-b2" data-ms-code data-ms-code-lang="ruby" data-controller="ms-code" data-ms-block …>
  <pre><code><span class="nb">puts</span> <span class="mi">1</span></code></pre>
  <pre hidden data-ms-code-source>puts 1</pre>
</div>
```

Plus: copy and download on code blocks and tables, a link-safety dialog, a
word-level reveal animation, autoscroll that gets out of the reader's way,
client-rendered diagrams and math, and markdown export.

## Agents

This engine is built for agent output, and a tool call is its own `Streamable`
record rather than a block inside the assistant's message — so each step of a
run seals, repairs and exports on its own, and two steps can be open at once,
which is what a parallel tool call is.

[Nexo](https://maquina.app/documentation/nexo/) is the agent harness it is built
alongside: `Agent#prompt` reports tool activity through a block, and each
`:tool_call` opens a record. `Message.stream_agent_run` in
`test/dummy/app/models/message.rb` is the whole bridge, and `/harness/agent`
runs it against a real model. See [streaming.md](docs/streaming.md#streaming-an-agent-run).

Nothing here depends on Nexo. Bare `ruby_llm`, or any client that hands you text
as it arrives, works the same way — `/harness/chat` is that version.

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

## maquina

Part of [maquina](https://maquina.app) — open source for Ruby and Ruby AI.

## License

MIT, © Mario Alberto Chávez. See [LICENSE.txt](LICENSE.txt).
