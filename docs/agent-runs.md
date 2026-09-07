# Streaming an agent run

A prose answer is one message. An agent run — Nexo's shape — is a loop: think,
call a tool, read the result, continue. Where do the steps live?

**Both shapes work with the contract as it stands**, and
`test/maquina_stream/agent_shapes_test.rb` is the proof. This is a product
decision, not an engine constraint.

**Decided 2026-09-07: shape A.** A tool call is its own `Streamable` record.
`test/maquina_stream/nexo_test.rb` drives it against a real `Nexo::Agent`, and
`test/dummy/app/models/message.rb` holds the whole bridge — Nexo reports tool
activity through the block `Agent#prompt` takes, each `:tool_call` opens a
record, each `:tool_result` seals one.

The deciding case is a tool result that arrives late. Under shape B it rewrites
blocks in the middle of a message whose tail has already moved on, which is
exactly what the seal lag cannot cover: the lag protects the last `seal_lag`
blocks, not a block twenty back. Under shape A the late result is simply its own
stream, still open, sealing when it finishes. Two streams open at once is also
what a parallel tool call IS, and shape B has no way to represent it.

## Shape A — each step is its own Streamable record

```ruby
thinking = Message.create!(conversation:, role: :assistant)
tool     = Message.create!(conversation:, role: :tool_call)
```

- Each step seals independently, with its own status. A tool call that errors
  does not mark the reasoning before it as errored.
- Each step has its own sequence and its own manifest, so a lost frame in one
  step never drags another into a repair.
- Steps of one conversation **share a cable stream** — that is what `stream_for:`
  is for, and one subscription per conversation is the point. Their frames never
  collide because block ids are namespaced by message id.
- The seal lag applies per step, so a two-block tool result seals as soon as the
  next step opens.

Choose this when steps have their own lifecycle in the UI: collapsing a tool
call, retrying one step, showing a per-step status.

## Shape B — the whole run is one buffer

````markdown
Voy a leer el archivo.

```tool_result
config/routes.rb: 12 líneas
```

El archivo define dos rutas.
````

- One record, one target, one export. The run reads back as a single document,
  which is what `MaquinaStream::Export.markdown` hands you.
- A tool result is a fenced block, so it goes through the fence registry like
  any other language — `:server` to highlight it, `:client` to render it with a
  controller, `:passthrough` to leave it alone.
- Verified: an earlier step's block digest does not change when a later step
  arrives, so ids stay stable across a run.

Choose this when the run reads as one answer and the steps are detail inside it.

## What does not change either way

- **Block ids are index-derived**, so they are stable within a record and
  namespaced across records.
- **The seal pointer still stops at unresolved references.** A run that writes
  `[docs]` in step one and defines it in step three keeps step one unsealed
  until the definition lands — in shape B automatically, and in shape A only if
  both are in the same record.
- **Repair is per record.** Whichever shape, each record reconciles against its
  own manifest.

## One caveat for shape A

A reference definition cannot cross records. If step one writes `[docs][ref]`
and step three defines `[ref]:`, the link never resolves in shape A, because
each record is rendered on its own — which is also why blocks are never rendered
in isolation within a record. If a run's steps genuinely share link references,
that is an argument for shape B.
