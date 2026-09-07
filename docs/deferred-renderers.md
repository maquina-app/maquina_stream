# Client-deferred renderers

Some things cannot be rendered on the server without shipping a rendering engine
with them — a Mermaid diagram, a KaTeX formula. Those render in the browser,
from **one JSON payload for one leaf node**.

This is not an exception to "only rendered HTML reaches the browser". The client
never parses markdown; it receives a payload for a single, already-identified
block and nothing else.

## What the engine ships

Two renderers, and no fence name for either. Which fence means "diagram" is your
decision:

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.register_fence "mermaid",
  strategy: :client,
  controller: "ms-diagram",
  payload: ->(source, info) { {source: source, info: info} }

MaquinaStream.register_fence "math",
  strategy: :client,
  controller: "ms-math",
  payload: ->(source, _info) { {source: source, display: true} }
```

Pin the libraries yourself. The engine never pins a third-party library — one
that pinned Mermaid would win or lose a version fight with your app for no
reason — and `preload: false` is what keeps the lazy import lazy:

```ruby
# config/importmap.rb
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/+esm", preload: false
pin "katex", to: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.mjs", preload: false
```

NoBuild: there is no lockfile, so the version lives in the importmap and nowhere
else.

## What it renders

While the fence is open there is no payload and no controller — just a skeleton:

````markdown
```mermaid
graph TD; A-->B;
````

```html
<div data-component="shimmer" role="status" aria-busy="true" aria-live="polite">
  <span class="sr-only">mermaid</span>
  …
</div>
```

Once it closes:

````markdown
```mermaid
graph TD; A-->B;
```
````

```html
<div data-controller="ms-diagram"
     data-ms-diagram-payload-value='{"source":"graph TD; A--\u003eB;\n","info":"mermaid"}'>
  <div data-ms-diagram-target="output" data-turbo-permanent>…shimmer…</div>
</div>
```

**Split ownership.** The payload attribute is server state and belongs to morph.
The output element is client state, is `data-turbo-permanent`, and belongs to
the controller. A repair morph that leaves the payload byte-identical fires no
value-changed callback, so it triggers no re-render and no flicker.

**No payload until the fence closes.** Handing the client half a diagram to draw
produces an error state for text that was merely still arriving.

## Writing your own

Nothing about a renderer lives in the engine. The registry carries the
controller name and the payload shape; the controller is yours.

```ruby
MaquinaStream.register_fence "timeline",
  strategy: :client,
  controller: "ms-timeline",
  payload: ->(source, info) { {source: source, info: info, format: "timeline"} }
```

```js
import MsDeferredController from "maquina_stream/controllers/ms_deferred_controller"

class MsTimelineController extends MsDeferredController {
  static library = null

  async library() {
    if (!this.constructor.library) {
      const timeline = await import("timeline")
      this.constructor.library = timeline.default ?? timeline
    }

    return this.constructor.library
  }

  async draw(payload) {
    const timeline = await this.library()
    return timeline.renderToString(String(payload.source ?? ""))
  }
}

application.register("ms-timeline", MsTimelineController)
```

Two methods: `library()` imports lazily and memoizes on the class, `draw(payload)`
returns a markup string. Everything else is decided for you.

`payload:` is a callable receiving `(source, info)` and returning a Hash; it
defaults to `{source:, info:}`. It is serialized as JSON into a data attribute,
so it must be JSON-representable.

`ms-timeline` appears nowhere in the engine. The dummy app registers exactly
this.

## What `ms-deferred` decides for every renderer

- **When to render.** On intersection, not on connect: a conversation scrolled
  back through hundreds of messages must not render hundreds of diagrams nobody
  is looking at. Set `data-ms-<name>-eager-value="true"` to override.
- **Lazy import.** The library is imported the first time something is actually
  about to draw. A page with no deferred content loads no renderer library.
- **Re-rendering.** Only when the payload really changed. A morph that leaves it
  byte-identical does nothing.
- **Sanitization of the output.** An allowlist, applied to whatever the library
  returns — SVG and MathML elements, the geometry and presentation attributes
  they need, and nothing that takes a URL except an `href` starting `https:`,
  `http:`, `mailto:` or `#`. The payload is model output and the library is
  third-party; neither is a reason to skip the check. This runs *in addition to*
  the server's sanitizer. See [security.md](security.md).
- **Failure.** A broken payload never breaks the message.

## The export fallback

**Show the source the model wrote.** That is the answer for every deferred
renderer, implemented once, and used for the error state, for
`MaquinaStream::Export.markdown`, and for any environment where the renderer
cannot run:

```html
<div data-ms-deferred-error role="note">
  <p>This block could not be rendered.</p>
  <pre>graph TD; A-->B;</pre>
</div>
```

Alt text would be a summary nobody wrote, and a server-rendered substitute would
mean shipping the rendering engine to the server — which is the reason these are
deferred at all.

The label is read from `data-ms-deferred-error-label` on the block itself, and
falls back to the English string above when there is none — JavaScript cannot
read `I18n`, and hardcoding the engine's default locale would show Spanish to a
host that never asked for it. A renderer of your own can put a translated label
on the element it renders.

## Security posture

| Renderer | Setting | What it buys |
|---|---|---|
| `ms-diagram` | `securityLevel: "strict"` | disables click handlers and inline HTML in diagram source, which is model output |
| `ms-math` | `trust: false` | refuses `\htmlClass`, `\includegraphics` and `\href`, all of which take attacker-controlled strings into the DOM |
| both | output allowlist | the library is third-party; its output is scrubbed before it reaches the DOM |

`ms-math` also runs with `throwOnError: false`, so a malformed formula degrades
to the fallback rather than taking the message down.

## Events

| Event | Detail |
|---|---|
| `ms:rendered` | `{controller}` |
| `ms:render-failed` | `{controller, error}` |
