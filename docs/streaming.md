# Streaming

What you implement, what the engine does with it, and where the line between
the two is.

## What the engine owns, and what you own

The engine renders markdown to HTML, splits it into blocks, decides which blocks
may freeze, works out what changed since the last frame, and emits Turbo Stream
actions. It serves the repair routes.

You own three things, and none of them has a default the engine could guess:

| Yours | Where it goes |
|---|---|
| Persisting the buffer, the sequence and the status | `MaquinaStream::Streamable` |
| Looking a record up by its stream id | `config.find_stream` |
| Deciding whether a request may see it | `config.authorize` |

The engine also never:

- guesses a broadcast target — `stream_for:` is yours;
- writes host columns other than through `#maquina_stream_append` and
  `#maquina_stream_seal!`;
- creates the `#ms-msg-<sid>` element it appends blocks into;
- sends markdown to the browser.

## The Streamable contract

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(m) { [:conversation, m.conversation_id, :messages] }
end
```

The macro generates each method below when its backing column exists:

| Method | Returns | Column it reads |
|---|---|---|
| `#maquina_stream_id` | `String`, stable and unique per message | none — it is `to_param` |
| `#maquina_stream_buffer` | `String`, the raw markdown so far | the one named by `buffer:` |
| `#maquina_stream_append(text)` | the whole buffer, appended and persisted | the one named by `buffer:` |
| `#maquina_stream_sequence` | `Integer`, monotonic, one per frame that went out | `stream_sequence` |
| `#maquina_stream_advance` | `Integer`, the next sequence number, incremented atomically | `stream_sequence` |
| `#maquina_stream_open?` | `Boolean` | `stream_status` |
| `#maquina_stream_status` | the end state as a Symbol, `nil` while open | `stream_status` |
| `#maquina_stream_seal!(status: :complete)` | the status Symbol it sealed with | `stream_status` |
| `#maquina_stream_target` | the Turbo broadcast target | none — it calls `stream_for:` |

`stream_status` holds `open` while the stream is being written; every other
value is a seal. The four seal statuses are `:complete`, `:cancelled`,
`:errored` and `:timed_out`. A stream that timed out is not one that errored:
nothing went wrong, the model simply stopped answering, and the partial text is
still worth keeping and replaying.

### When your columns are named differently

The macro includes a module, so anything you define in the class body wins:

```ruby
class Message < ApplicationRecord
  include MaquinaStream::Streamable
  maquina_stream buffer: :body, stream_for: ->(m) { [m.chat, :messages] }

  def maquina_stream_sequence = frame_number
  def maquina_stream_open? = finished_at.nil?
  def maquina_stream_seal!(status: :complete) = update!(finished_at: Time.current, outcome: status)
end
```

A model that cannot use the macro at all implements the nine methods itself and
never includes the concern.

### When the contract is unmet

Calling a method whose column is missing raises `MaquinaStream::ContractError`,
naming the method, the column and the class:

```
Note does not satisfy MaquinaStream::Streamable: #maquina_stream_sequence
needs a `stream_sequence` column, and Note has none. Add the column,
or define #maquina_stream_sequence on Note yourself.
```

`Message.maquina_stream_contract_gaps` answers the same question without calling
anything, and is worth one assertion in your own suite:

```ruby
assert_empty Message.maquina_stream_contract_gaps   # => []
```

### The broadcast target

`stream_for:` receives the record and returns whatever `Turbo::StreamsChannel`
accepts as a stream name — a record, an array, a string:

```ruby
maquina_stream stream_for: ->(m) { [:conversation, m.conversation_id, :messages] }
```

The page subscribes to the same thing:

```erb
<%= turbo_stream_from :conversation, @conversation.id, :messages %>
```

The stream name is yours, which means who may subscribe is yours too. Sign or
scope it exactly as you would any other Turbo stream. If `stream_for:` is
missing or not callable, `#maquina_stream_target` raises rather than guessing.

## The broadcaster

```ruby
broadcaster = MaquinaStream::Broadcaster.new(message)
model.stream { |token| broadcaster.append(token) }
broadcaster.seal!
```

`#append(text)` appends to your column — the host owns persistence, so it writes
first and only then has something to broadcast — and emits a frame if the frame
budget has elapsed. It returns the `Frame` that went out, or `nil` when this
append was coalesced into the next one.

`#broadcast` emits without appending, for a buffer that moved by some other
route. `#seal!(status:)` seals the record and emits the final frame.

**One broadcaster per stream, held for the life of that stream.** What the
browser already has lives in the instance, so a fresh broadcaster mid-stream
re-sends every block. It is not thread-safe; drive one stream from one place.

### What a frame carries

A frame appends the blocks the browser has never seen and patches the open tail,
and nothing else. A block that has not changed is never re-sent, which is the
difference between bandwidth tracking drift and bandwidth tracking message
length.

```ruby
b = MaquinaStream::Broadcaster.new(message)
b.append("# Informe\n\n")
b.append("Todo bien.\n\n")
b.append("Segunda parte.\n")
b.seal!
```

```
seq=1 final=false appends=["ms-1-b0"] patch=[]
seq=2 final=false appends=["ms-1-b1"] patch=[]
seq=3 final=false appends=["ms-1-b2"] patch=[]
seq=4 final=true  appends=[]          patch=[]
```

Over the wire, appends go out as `broadcast_append_to` against
`#ms-msg-<sid>`; patches as `broadcast_replace_to` with `method: "morph"`, so
idiomorph patches the node in place instead of recreating it. Every stream
action carries `data-ms-seq` and `data-ms-frame`, and the final one is marked
`final`.

Block ids are index-derived (`ms-<sid>-b<n>`), never content-derived, because
idiomorph keys on `id` and a content-derived id makes morph delete and recreate.

### Coalescing

Frames inside `frame_budget_ms` accumulate instead of going out one per token,
and the coalescing happens *before* the render rather than after it: building a
frame means rendering the whole buffer, so doing that per token and throwing the
result away is how a stream becomes quadratic in message length.

Skipping a frame costs nothing. The next one is computed against what the
browser actually has, so it carries the accumulated difference. Choosing the
budget is in [configuration.md](configuration.md).

### Deltas are an optimization

Only the open tail is patched. A block that changes after it has stopped being
the tail — a heading that completes as the paragraph below it begins — is left
for the repair path, which fixes it for free because that is a *content* change
and content is exactly what a manifest digest covers. See [repair.md](repair.md).

## Sealing

**Always seal, including when the stream failed.** The client has no other way
to learn the stream is over, and the final frame is never coalesced and never
skipped: it is what makes every intra-stream drift cosmetic and self-correcting.

```ruby
def stream_from(chat, prompt, broadcaster: MaquinaStream::Broadcaster.new(self))
  chat.ask(prompt) { |chunk| broadcaster.append(chunk.content.to_s) }
  broadcaster.seal!
rescue
  broadcaster.seal!(status: :errored)
  raise
end
```

A run that raises somewhere else — a timeout, a refusal, an endpoint that went
away — can leave records still open, and an open record is a client waiting for
a frame that is never coming. Only you know the run ended, so only you can send
that frame:

```ruby
def self.seal_abandoned!(conversation_id:)
  where(conversation_id: conversation_id, stream_status: "open").each do |record|
    MaquinaStream::Broadcaster.new(record).seal!(status: :errored)
    record.broadcast_shell
  end
end
```

Sealing through `Broadcaster#seal!` emits the final frame. Calling
`record.maquina_stream_seal!` directly only records the status — use that when
you mean to close a stream silently.

`Message#broadcast_shell` in the dummy app shows the other half: re-broadcasting
the message wrapper as a morph once it seals, which is what takes
`data-ms-streaming` off, stops the reveal and re-enables the controls.

## Streaming an agent run

An agent run is a loop — think, call a tool, read the result, continue. **A tool
call is its own `Streamable` record**, not a block inside the assistant's
message.

```ruby
thinking = Message.create!(conversation_id: id, role: "assistant")
tool     = Message.create!(conversation_id: id, role: "tool", tool_name: "read_file")
```

- Each step seals independently, with its own status. A tool call that errors
  does not mark the reasoning before it as errored.
- Each step has its own sequence and its own manifest, so a lost frame in one
  step never drags another into a repair.
- Steps of one conversation **share a cable stream** — that is what `stream_for:`
  is for. Their frames never collide, because block ids are namespaced by
  message id.
- Two streams open at once is what a parallel tool call *is*, and there is no
  other way to represent it.
- A late tool result is simply its own stream, still open, sealing when it
  finishes. Held inside one buffer it would instead rewrite blocks in the middle
  of a message whose tail has already moved on — which is exactly the case
  `seal_lag` cannot cover, because the lag protects the last few blocks, not one
  twenty back.

One caveat: a markdown link reference cannot cross records. If step one writes
`[docs][ref]` and step three defines `[ref]:`, the link never resolves, because
each record is rendered on its own. If a run's steps genuinely share link
references, keep them in one record.

`Message.stream_agent_run` in `test/dummy/app/models/message.rb` is a worked
example against a real [Nexo](https://maquina.app/documentation/nexo/) agent,
and `/harness/agent` runs it. Nexo reports tool activity through the block
`Agent#prompt` takes, so each `:tool_call` opens a record and each
`:tool_result` seals one. Nothing in the engine depends on it — any client
that hands you text as it arrives works the same way.

## History, and rendering a sealed message

A sealed message is immutable, so render it through the cache:

```erb
<%= MaquinaStream.render(message) %>
```

```html
<h1 id="ms-1-b0" data-ms-element="h1" data-ms-block data-ms-block-digest="bebc578f97924e6b">Informe…</h1>
<p id="ms-1-b1" data-ms-element="p" data-ms-block data-ms-block-digest="1bc2ef335d92b2a5">Todo bien.</p>
<p id="ms-1-b2" data-ms-element="p" data-ms-block data-ms-block-digest="453593ffc6cfefe9">Segunda parte.</p>
```

Cached by buffer digest once sealed, rendered live while open, and a new key if
you edit the message. Re-rendering fifty finished messages on every page load is
work nobody asked for.

Pagination is yours — which messages, in what order. `/history` in the dummy app
shows one pattern: a lazy Turbo Frame at the top of each page loads the page
above it on scroll, so history grows upward without a pagination bar.

Live, reload, replay and export produce the same document byte for byte. There
is no separate "streaming mode" output to reconcile against a "static" one.

## Export

```ruby
MaquinaStream::Export.markdown(message)
```

The buffer already *is* markdown, so export is mostly a question of the parts
that are not clean. A cancelled stream ends mid-token, so the buffer is repaired
first with the same preprocessor the renderer uses — an export matches what was
on screen:

```ruby
message.content              # => "Un **inform"
MaquinaStream::Export.markdown(message)
# => "Un **inform**\n\n> _Respuesta cancelada antes de terminar._\n"
```

Anything that did not finish gets a status footer, because a cancelled message
that exports as though it were complete is a lie in a file somebody keeps. Pass
`annotate: false` to suppress it — for a caller re-ingesting the text that will
carry the status some other way.

Deferred content exports as its source: a diagram exports as its `mermaid`
fence, verbatim, because that is what the model wrote and what another tool can
read.
