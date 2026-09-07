# Client-deferred renderers

Some things cannot be rendered on the server without shipping a rendering engine
with them — a Mermaid diagram, a KaTeX formula. Those render in the browser,
from **one JSON payload for one leaf node**.

This is not an exception to "only rendered HTML reaches the browser". The client
never parses markdown; it receives a payload for a single, already-identified
block and nothing else.

## The pattern

```html
<div data-controller="ms-diagram"
     data-ms-diagram-payload-value='{"source":"graph TD…","info":"mermaid"}'>
  <div data-ms-diagram-target="output" data-turbo-permanent>…</div>
</div>
```

**Split ownership.** The payload attribute is server state and belongs to morph.
The output element is client state and belongs to the controller. A repair morph
that leaves the payload byte-identical fires no value-changed callback, so it
triggers no re-render and no flicker — verified, not assumed.

**No payload until the fence closes.** An open fence renders the `shimmer`
skeleton and carries no payload at all; handing the client half a diagram to
draw produces an error state for text that was merely still arriving.

## Adding a renderer, host-side only

Nothing about a renderer lives in the engine. The registry carries the
controller name and the payload shape:

```ruby
MaquinaStream.register_fence "timeline",
  strategy: :client,
  controller: "ms-timeline",
  payload: ->(source, info) { {source: source, info: info, format: "timeline"} }
```

```js
import MsDeferredController from "maquina_stream/controllers/ms_deferred_controller"

class MsTimelineController extends MsDeferredController {
  async draw(payload) { return renderTimeline(payload.source) }
}

application.register("ms-timeline", MsTimelineController)
```

`ms-timeline` appears nowhere in the engine. The dummy app registers exactly
this, which is the Phase 6 DoD line about the registry being open.

## What `ms-deferred` decides for every renderer

- **When to render.** On intersection, not on connect: a conversation scrolled
  back through hundreds of messages must not render hundreds of diagrams nobody
  is looking at. `eager` overrides it.
- **Lazy import.** The library is imported the first time something is actually
  about to draw. A page with no deferred content loads no renderer library.
- **Sanitization of the output.** An allowlist, applied to whatever the library
  returns. The payload is model output and the library is third-party; neither
  is a reason to skip the check. This runs *in addition to* the server's
  sanitizer, per CLAUDE.md, and has its own regression coverage because a hole
  here would not be caught by the server's suite.
- **Failure.** A broken payload never breaks the message: the block degrades to
  the export fallback and the rest of the document is untouched.

## The export fallback, decided once

**Show the source the model wrote.** Same answer for every deferred renderer,
implemented once in `ms-deferred#fail`, and used for the error state, for export
and for any environment where the renderer cannot run. Alt text is a summary
nobody wrote, and a server-rendered substitute would mean shipping the rendering
engine to the server — which is the reason these are deferred at all.

## Security posture per renderer

| Renderer | Setting | Why |
|---|---|---|
| `ms-diagram` | `securityLevel: "strict"` | disables click handlers and inline HTML in diagram source, which is model output |
| `ms-math` | `trust: false` | refuses `\htmlClass`, `\includegraphics`, `\href` — all of which take attacker-controlled strings into the DOM |
| both | output allowlist | the library is third-party; its output is scrubbed before it reaches the DOM |

## Verified in a browser

Against the harness, with a stub renderer that returns deliberately hostile
markup:

- `<script>`, `<iframe>`, `onload=` and `style=` are stripped; a
  `javascript:` href is dropped while `https:` survives; legitimate SVG renders.
- Nothing executes — the hostile payload sets no global.
- A byte-identical payload after a morph triggers **zero** re-renders; a changed
  one triggers exactly one.
- A renderer that throws degrades to the source fallback, and the rest of the
  message is intact.

## Pinning the libraries

Libraries are the host's pins, not the engine's — an engine that pinned Mermaid
would win or lose a version fight with the app for no reason:

```ruby
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"
pin "katex",   to: "https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.mjs"
```

NoBuild: there is no lockfile, so the version lives in the importmap and nowhere
else.
