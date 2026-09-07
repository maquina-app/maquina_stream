# Repair

## What it is for

Action Cable gives no delivery guarantee, no ordering guarantee and no gap
detection. A frame can simply not arrive: a flaky connection, a backgrounded
tab, a reconnect in the middle of a message. Deltas are an optimization, and
they do not converge on their own — only the open tail is patched, so a block
that changes after it has stopped being the tail is never re-sent.

The repair path is where correctness lives. The browser periodically asks the
server what the message currently is, compares that against its own DOM, and
asks for the blocks that differ.

If you fix a correctness bug inside the delta path, you have fixed it in the
wrong place.

## What you must implement

Three things, and then it runs on its own.

### 1. Mount the engine

```ruby
# config/routes.rb
mount MaquinaStream::Engine => "/maquina_stream"
```

### 2. Configure the two seams

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.configure do |c|
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize = ->(record, request) { record.conversation.readable_by?(request) }
end
```

`find_stream` receives the `:sid` from the URL — that is `#maquina_stream_id`,
which defaults to `to_param` — and returns a record or `nil`. Return `nil` and
the engine answers `404`. Leave it unset and every engine request raises
`MaquinaStream::ConfigurationError`: the engine does not go looking for a model
on its own.

`authorize` receives the record and the `ActionDispatch::Request`. Anything
falsy answers `403`. **Leaving it unset denies everything**; there is no
permissive default, because an engine that guesses is an engine that leaks.

Scope the lookup rather than relying on `authorize` alone where you can — the
same advice as any Rails controller:

```ruby
c.find_stream = ->(sid) { Current.user.messages.find_by(id: sid) }
```

### 3. Put the repair URLs on the message element

```erb
<div id="ms-msg-<%= message.maquina_stream_id %>"
     data-controller="ms-repair"
     data-ms-repair-manifest-url-value="<%= maquina_stream.manifest_path(sid: message.maquina_stream_id) %>"
     data-ms-repair-blocks-url-value="<%= maquina_stream.blocks_path(sid: message.maquina_stream_id) %>"
     data-ms-repair-interval-value="4000"><%= MaquinaStream.render(message) %></div>
```

`maquina_stream.` is the mounted engine's route proxy, so the paths follow
wherever you mounted it. `data-ms-repair-interval-value` defaults to 4000ms;
`0` turns the keyframe timer off and leaves the other three triggers.

That is all. The blocks the engine renders already carry the `id`,
`data-ms-block` and `data-ms-block-digest` the controller diffs on.

## The two routes

### `GET /maquina_stream/:sid/manifest`

What the browser is told the message currently *is*, in a bounded number of
bytes. Not HTML.

```json
{"seq":7,"cutoff":0,"rollup":"e3b0c44298fc1c14",
 "blocks":[["ms-42-b0","999bd5bd2841c435"],["ms-42-b1","6c7c33d9dcefa12c"]]}
```

| Key | Meaning |
|---|---|
| `seq` | the sequence number this manifest describes |
| `cutoff` | how many sealed blocks fall behind the window |
| `rollup` | one digest covering every block behind the cutoff |
| `blocks` | `[[id, digest], …]` for the blocks inside the window |

Only sealed blocks are listed — an open block is about to change, so there is
nothing to reconcile it against. With the default `seal_lag` of 2, the last two
blocks of a message are absent from the manifest by design.

The manifest is windowed rather than complete because listing every sealed block
made it track message length almost exactly: 1.8KB for a 2KB message, 88KB for a
100KB one, sent every keyframe. The last `manifest_window` sealed blocks go in
full, and one rollup digest covers everything older. A client whose rollup
matches knows its history is intact and only has to consider the window; a
client whose rollup differs asks for the whole thing with `?full=1`, which is
rare and no more expensive than the cold page load it resembles.

### `GET /maquina_stream/:sid/blocks?ids[]=…`

The blocks the client asked for, as morphing Turbo Stream actions.

```html
<turbo-stream method="morph" action="replace" target="ms-42-b1">
  <template><p id="ms-42-b1" data-ms-element="p" data-ms-block data-ms-block-digest="6c7c33d9dcefa12c">Dos</p></template>
</turbo-stream>
```

`method="morph"` is what makes the repair silent: idiomorph patches the existing
node in place, so client state inside it survives and no animation fires for a
replacement that never happens.

`ids` comes from the client, so it is filtered against the document rather than
trusted — only ids the message actually has are served, and only the ones
requested. A request for every block is a legitimate cold repair, so the count
is not capped, but each id is matched, never interpolated.

Asking to repair nothing is a normal answer to a manifest that already agreed,
and returns an empty stream rather than an error.

## What the browser does with them

`ms-repair` fetches on four triggers:

1. the final seal, always;
2. a gap in the sequence — every stream action carries `data-ms-seq`;
3. a reconnect, or the tab becoming visible again;
4. the periodic keyframe.

It compares the manifest against its own DOM, requests only the blocks whose
digests differ, and morphs them in. Repair therefore costs what has drifted, not
what the message weighs.

Before the morph it dispatches `ms:suppress` on the message element and
`ms:resume` after it, so the reveal animation unwraps whatever was mid-flight
and re-baselines afterwards — a repair never re-reveals text the reader has
already read.

It dispatches `ms:repaired` (with `{reason, blocks}`) and `ms:repair-failed`
(with `{reason, error}`) if you want to observe it. See
[javascript.md](javascript.md).

## Responses you should expect

| Situation | Response |
|---|---|
| `find_stream` returns `nil` | `404` |
| `authorize` returns falsy | `403` |
| `authorize` not configured | `403` |
| `find_stream` not configured | `MaquinaStream::ConfigurationError` |

## Transport independence

The repair path is plain `GET`, so a client that lost frames recovers over HTTP
no matter how those frames were delivered. Frames, sequence numbers, the
manifest and these two routes are transport-independent by construction — which
is what makes `config.transport` a seam worth having rather than a setting.
