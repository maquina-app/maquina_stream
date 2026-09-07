# Getting started

From `bundle add maquina_stream` to a message streaming into a browser.

## 1. Install

```ruby
# Gemfile
gem "maquina_stream"
```

Rails 8, Ruby 3.3+. The engine pulls in `maquina_remend`, `commonmarker`,
`nokogiri` and `rouge`. `maquina_components` is optional; without it the engine
renders its own Tailwind fallbacks.

Mount the engine. It contributes two `GET` routes — the repair path — and
nothing else:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount MaquinaStream::Engine => "/maquina_stream"
end
```

The engine ships no migrations and no models. **The host owns persistence.**

## 2. The migration

The `maquina_stream` macro generates its contract methods from three columns:
the one you name as the buffer, plus `stream_sequence` and `stream_status`.

```ruby
create_table :messages do |t|
  t.references :conversation
  t.text    :content,         null: false, default: ""
  t.integer :stream_sequence, null: false, default: 0
  t.string  :stream_status,   null: false, default: "open"
  t.timestamps
end
```

`stream_status` holds one of `open`, `complete`, `cancelled`, `errored` or
`timed_out`.

## 3. The Streamable model

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(m) { [:conversation, m.conversation_id, :messages] }
end
```

`buffer:` names the column holding the raw markdown. `stream_for:` is a
callable that returns the Turbo broadcast target — the engine never guesses one,
because who may subscribe to a stream is your question, not the engine's.

Assert the contract in your own suite, so a missing column fails at test time
rather than mid-stream:

```ruby
test "Message satisfies the maquina_stream contract" do
  assert_empty Message.maquina_stream_contract_gaps
end
```

The full method table and what to do when your columns are named differently is
in [streaming.md](streaming.md).

## 4. Configure the two host seams

The engine resolves nothing and authorizes nothing on its own.

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize = ->(record, request) { record.conversation.readable_by?(request) }
end
```

**With no `authorize` configured, every repair request is refused.** With no
`find_stream`, every repair request raises. See [repair.md](repair.md).

Every other option has a working default. [configuration.md](configuration.md)
lists them.

## 5. The view

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
wherever you mounted it.

`data-ms-streaming` is the one attribute you have to keep correct. It is stamped
from `maquina_stream_open?`, and everything derived from "this message is still
being written" reads it: the caret CSS, the reveal animation, and the guard that
keeps copy and download buttons inert while a code block is half-arrived.
Taking it off is what a seal looks like in the DOM.

Load the reveal stylesheet and, if you want highlighting colours, the generated
themes:

```erb
<%= stylesheet_link_tag "maquina_stream/reveal" %>
<%= stylesheet_link_tag "maquina_stream/themes/light" %>
<%= stylesheet_link_tag "maquina_stream/themes/dark" %>
```

## 6. The JavaScript

Importmap, no build step. The engine appends its own pins to your importmap; it
pins nothing third-party, not even Stimulus.

```js
// app/javascript/application.js
import "@hotwired/turbo-rails"
import { Application } from "@hotwired/stimulus"
import { registerMaquinaStreamControllers } from "maquina_stream"

const application = Application.start()
registerMaquinaStreamControllers(application)
```

The engine registers its own identifiers rather than relying on your eager-load
glob, because those identifiers are part of the DOM contract. See
[javascript.md](javascript.md).

## 7. Stream one message end to end

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

Subscribe the page to the same target you gave `stream_for:`:

```erb
<%= turbo_stream_from :conversation, @conversation.id, :messages %>
<div id="messages">
  <%= render @messages %>
</div>
```

## 8. Watch it work

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

## Where to go next

- [streaming.md](streaming.md) — the contract in full, sealing, agent runs
- [configuration.md](configuration.md) — every option and how to choose
- [repair.md](repair.md) — what the two routes do and what you must implement
- [registries.md](registries.md) — teach the renderer about your own fences and tags
