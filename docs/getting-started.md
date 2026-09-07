# Getting started

From `bundle add maquina_stream` to a message streaming into a browser: two
commands, two seams you fill in yourself, one view.

## 1. Install

```ruby
# Gemfile
gem "maquina_stream"
```

Rails 8, Ruby 3.3+. The engine pulls in `maquina_remend`, `commonmarker`,
`nokogiri` and `rouge`. `maquina_components` is optional; without it the engine
renders its own Tailwind fallbacks.

It ships no migrations and no models. **The host owns persistence.**

**Turbo is required.** Repair applies Turbo Stream morphs, and with
`window.Turbo` undefined every repair fails inside a catch — the message stops
being correct and nothing in the browser says so. The install generator pins it
if your Gemfile has `turbo-rails` and refuses loudly if it does not.

## 2. Two commands

```sh
bin/rails generate maquina_stream:install
bin/rails generate maquina_stream:streamable Message
```

```
      create  config/initializers/maquina_stream.rb
       route  mount MaquinaStream::Engine => "/maquina_stream"
      append  config/importmap.rb
      append  app/javascript/controllers/index.js
      insert  app/views/layouts/application.html.erb

      create  db/migrate/20260101000000_create_messages.rb
      create  app/models/message.rb
        gsub  config/initializers/maquina_stream.rb
```

Both are idempotent and neither overwrites a file. Re-run them as often as you
like; anything already in place is reported and left alone. A step whose
ingredient is missing — no importmap, no Stimulus entrypoint, no layout — prints
the exact content to paste rather than failing or silently doing nothing.

`streamable` is per model, because a host may have several: an assistant
message and a tool call are two streams, not one.

```sh
bin/rails db:migrate
```

The migration carries the three columns the contract needs — the buffer, plus
`stream_sequence` and `stream_status` — and generates them from
`MaquinaStream::Streamable` itself, so it cannot drift from the contract
`maquina_stream_contract_gaps` checks. A model whose table already exists gets
`add_column` for only the columns it lacks.

| Flag | What it does |
|---|---|
| `--buffer=body` | Names a different column as the markdown buffer |
| `--stream-for="[:conversation, record.conversation_id, :messages]"` | Sets the Turbo broadcast target |
| `--deferred-renderers` (install) | Also pins `mermaid` and `katex`, with `preload: false` |

Assert the contract in your own suite, so a missing column fails at test time
rather than mid-stream:

```ruby
test "Message satisfies the maquina_stream contract" do
  assert_empty Message.maquina_stream_contract_gaps
end
```

## 3. The two seams

The generators write everything the engine can know. These two it cannot.

### `authorize`, in the initializer

```ruby
# config/initializers/maquina_stream.rb
c.authorize = ->(record, request) { false }   # ← the generated stub
```

**As generated it denies every repair request.** That is the safe failure and a
broken feature both: the browser can never repair a message until you replace
it. Guessing a host's authorization is how an engine leaks other people's
messages, so it guesses nothing.

```ruby
c.authorize = ->(record, request) do
  record.conversation.member?(request.session[:user_id])
end
```

`find_stream` is the other seam, and `maquina_stream:streamable` fills it in:

```ruby
c.find_stream = ->(sid) { Message.find_by(id: sid) }
```

Unset, it raises rather than returning `nil` — a silent `nil` would look like a
missing record rather than a missing seam. Every other option in the generated
initializer is commented, with the default it already has.
[configuration.md](configuration.md) explains each one.

### `stream_for:`, in the model

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(record) { record }
end
```

`stream_for:` returns the Turbo broadcast target. The generated one gives every
message a stream of its own; a conversation-wide target is usually what you
want:

```ruby
stream_for: ->(record) { [:conversation, record.conversation_id, :messages] }
```

The engine never guesses one, because who may subscribe to a stream is your
question, not the engine's.

## 4. The view

The engine appends block HTML into `#ms-msg-<sid>` and never creates that
element. The wrapper, the controllers on it and its repair URLs are yours:

```erb
<%# app/views/messages/_message.html.erb %>
<article id="live-msg-<%= message.maquina_stream_id %>">
  <div id="ms-msg-<%= message.maquina_stream_id %>"
       data-controller="ms-repair ms-reveal"
       data-ms-repair-manifest-url-value="<%= maquina_stream.manifest_path(sid: message.maquina_stream_id) %>"
       data-ms-repair-blocks-url-value="<%= maquina_stream.blocks_path(sid: message.maquina_stream_id) %>"
       data-ms-repair-interval-value="4000"
       <%= "data-ms-streaming" if message.maquina_stream_open? %>><%= MaquinaStream.render(message) %></div>
</article>
```

`maquina_stream.` is the mounted engine's route proxy, so those two paths follow
wherever the install generator mounted it.

`data-ms-streaming` is the one attribute you have to keep correct. It is stamped
from `maquina_stream_open?`, and everything derived from "this message is still
being written" reads it: the caret CSS, the reveal animation, and the guard that
keeps copy and download buttons inert while a code block is half-arrived.
Taking it off is what a seal looks like in the DOM.

Subscribe the page to the same target you gave `stream_for:`:

```erb
<%= turbo_stream_from :conversation, @conversation.id, :messages %>
<div id="messages">
  <%= render @messages %>
</div>
```

## 5. Stream one message end to end

Create the record, broadcast an empty shell so the browser has somewhere to put
blocks, then feed the broadcaster:

```ruby
class Message < ApplicationRecord
  # …

  def broadcast_shell
    if maquina_stream_open?
      Turbo::StreamsChannel.broadcast_append_to(
        maquina_stream_target,
        target: "messages",
        partial: "messages/message",
        locals: {message: self}
      )
    else
      Turbo::StreamsChannel.broadcast_replace_to(
        maquina_stream_target,
        target: "live-msg-#{maquina_stream_id}",
        partial: "messages/message",
        locals: {message: self},
        attributes: {"method" => "morph"}
      )
    end
  end

  def stream_from(chat, prompt, broadcaster: MaquinaStream::Broadcaster.new(self))
    chat.ask(prompt) do |chunk|
      text = chunk.content.to_s
      broadcaster.append(text) unless text.empty?
    end

    broadcaster.seal!
  rescue
    broadcaster.seal!(status: :errored)
    raise
  end
end
```

```ruby
message = Message.create!(conversation: conversation)
message.broadcast_shell
message.stream_from(chat, params[:prompt])
message.broadcast_shell   # again, now sealed: takes data-ms-streaming off
```

The shell goes out twice — once empty when the record opens, once more when it
seals. The second one morphs, so the blocks the deltas already delivered are
reconciled rather than deleted and recreated.

**Always seal.** A stream that ends without a seal leaves every client waiting
for a frame that never arrives; that is why the `rescue` above seals as
`errored` before re-raising.

## 6. Watch it work

Two live pages in `test/dummy` talk to a real model rather than a fixture:

| Page | What it is |
|---|---|
| `/harness/chat` | Bare `ruby_llm`. `chat.ask` yields chunks, one record, one seal. |
| `/harness/agent` | [Nexo](https://maquina.app/documentation/nexo/). One `Streamable` record per step of an agent run. |

Both read `test/dummy/config/llm.yml`, which is git-ignored. Copy the example
and point it at any OpenAI-compatible endpoint — ollama, vLLM, LM Studio,
OpenRouter and OpenAI itself all speak it:

```sh
cp test/dummy/config/llm.yml.example test/dummy/config/llm.yml
cd test/dummy && bundle exec puma -p 3001 config.ru
# http://localhost:3001/harness
```

There is no ENV fallback and no default host: a missing or half-written file
makes the pages say what to create rather than fail against somebody else's
endpoint.

`/harness` itself is the fixture page — every control, the link dialog, the
autoscroll pane, the deferred renderers — and `/history` shows a page of sealed
messages served from the render cache.

## What the generators do for you

Every step, for a host that would rather do it by hand — or that has to,
because it uses a bundler instead of importmaps.

### `maquina_stream:install`

**The initializer**, `config/initializers/maquina_stream.rb`, with every option
commented at its default and the two seams stubbed:

```ruby
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize = ->(record, request) { record.conversation.readable_by?(request) }
end
```

**The mount**, in `config/routes.rb`. The engine contributes two `GET` routes —
the repair path — and nothing else:

```ruby
mount MaquinaStream::Engine => "/maquina_stream"
```

**The Turbo pin**, in `config/importmap.rb`. The engine appends its own pins to
your importmap through its engine initializer, and pins nothing third-party —
not even Stimulus, because an engine that pinned it would win or lose a version
fight with your app for no reason:

```ruby
pin "@hotwired/turbo-rails", to: "turbo.min.js"
```

**The Stimulus registration**, appended to `app/javascript/controllers/index.js`
or, failing that, to whichever entrypoint calls `Application.start()`:

```js
import { registerMaquinaStreamControllers } from "maquina_stream"
registerMaquinaStreamControllers(application)
```

The engine registers its own identifiers rather than relying on your eager-load
glob, because those identifiers are part of the DOM contract. See
[javascript.md](javascript.md).

**The stylesheets**, injected into the layout's `<head>`:

```erb
<%= stylesheet_link_tag "maquina_stream/reveal" %>
<%= stylesheet_link_tag "maquina_stream/themes/light" %>
<%= stylesheet_link_tag "maquina_stream/themes/dark" %>
```

**The deferred-renderer pins**, with `--deferred-renderers`:

```ruby
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/+esm", preload: false
pin "katex", to: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.mjs", preload: false
```

`preload: false` is load-bearing. importmap-rails preloads by default, which
emits a `<link rel="modulepreload">` and fetches both libraries on every page —
exactly the cost the lazy import inside the deferred controller exists to
avoid. Pin an exact version: NoBuild means no lockfile, so the version lives
there and nowhere else.

### `maquina_stream:streamable`

**The migration.** The `maquina_stream` macro generates its contract methods
from three columns: the one you name as the buffer, plus `stream_sequence` and
`stream_status`.

```ruby
create_table :messages do |t|
  t.text    :content,         null: false, default: ""
  t.integer :stream_sequence, null: false, default: 0
  t.string  :stream_status,   null: false, default: "open"
  t.timestamps
end
```

`stream_status` holds one of `open`, `complete`, `cancelled`, `errored` or
`timed_out`.

**The model**, created if it is missing and injected into if it is not:

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(record) { record }
end
```

**The `find_stream` seam**, but only when it is still the stub the install
generator wrote. One you wrote yourself is never touched.

The full method table, and what to do when your columns are named differently,
is in [streaming.md](streaming.md).

## Where to go next

- [streaming.md](streaming.md) — the contract in full, sealing, agent runs
- [configuration.md](configuration.md) — every option and how to choose
- [repair.md](repair.md) — what the two routes do and what you must implement
- [registries.md](registries.md) — teach the renderer about your own fences and tags
