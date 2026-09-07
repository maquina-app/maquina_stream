# JavaScript

Nine Stimulus controllers, shipped as source and pinned into your importmap.
There is no build step, no `package.json` and no npm dependency, and nothing
here imports a third-party library at load time.

## Registering

```js
// app/javascript/application.js
import "@hotwired/turbo-rails"
import { Application } from "@hotwired/stimulus"
import { registerMaquinaStreamControllers } from "maquina_stream"

const application = Application.start()
registerMaquinaStreamControllers(application)
```

The engine registers its own identifiers rather than relying on your eager-load
glob, because those identifiers are part of the DOM contract and must not depend
on where you keep your files.

`registerMaquinaStreamControllers` also wires one `turbo:before-cache` listener
that calls `teardown()` on any controller that defines it, so a controller that
mutated the DOM rolls that back before Turbo snapshots the page.

## Importmap

The engine appends its own pins to your importmap automatically. It pins only
its own source: `@hotwired/stimulus` stays your pin, because an engine that
pinned it would win or lose a version fight with your app for no reason.

Libraries the deferred renderers need are yours too:

```ruby
# config/importmap.rb
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/+esm", preload: false
pin "katex", to: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.mjs", preload: false
```

`preload: false` is load-bearing. importmap-rails preloads by default, which
emits a `<link rel="modulepreload">` and fetches both libraries on every page —
exactly the cost the lazy import inside the deferred controller exists to avoid.

## The controllers

| Identifier | Job | Mounted by |
|---|---|---|
| `ms-repair` | manifest diff, block fetch, silent morph, keyframe timer | you, on the message element |
| `ms-reveal` | animates the text that just arrived | you, on the message element |
| `ms-autoscroll` | stick to the bottom, release when the reader scrolls up | you, on whatever scrolls |
| `ms-link-safety` | confirmation dialog before following a link out | you, around the message |
| `ms-code` | copy and download a code block | the renderer |
| `ms-table` | copy and download a table, toggle fullscreen | the renderer |
| `ms-deferred` | base class: lazy import, render on payload change, sanitize output | — |
| `ms-diagram`, `ms-math` | extend `ms-deferred` | the renderer, per the fence registry |

The renderer emits everything the controllers need **inside** a message. Four
are yours, because they are page-level rather than message-level.

**Mounting a controller without its actions is silent.** Nothing errors; the
controller simply never hears anything. Check the `data-action` when a control
seems dead.

## The message element

```erb
<div id="ms-msg-<%= message.maquina_stream_id %>"
     data-controller="ms-repair ms-reveal"
     data-ms-repair-manifest-url-value="<%= maquina_stream.manifest_path(sid: message.maquina_stream_id) %>"
     data-ms-repair-blocks-url-value="<%= maquina_stream.blocks_path(sid: message.maquina_stream_id) %>"
     data-ms-repair-interval-value="4000"
     <%= "data-ms-streaming" if message.maquina_stream_open? %>><%= MaquinaStream.render(message) %></div>
```

`data-ms-streaming` is the one attribute you have to keep correct, and
everything about "this message is still being written" derives from it. Blocks
carry no streaming state of their own: a block is exactly its content plus its
identity, so two tabs holding the same content hold the same DOM, and a block's
bytes never disagree with the digest repair compares them by.

The caret is CSS, reading the same attribute:

```css
[data-ms-streaming] > [data-ms-block]:last-child::after { /* caret */ }
```

Controllers find the message element by `#ms-msg-<sid>`; if you wrap rendered
output some other way, mark your wrapper `data-ms-message`.

### `ms-repair`

| Value | Default | Meaning |
|---|---|---|
| `data-ms-repair-manifest-url-value` | — | required |
| `data-ms-repair-blocks-url-value` | — | required |
| `data-ms-repair-interval-value` | `4000` | keyframe period in ms; `0` disables the timer |
| `data-ms-repair-seq-value` | `0` | last sequence seen |
| `data-ms-repair-rollup-value` | `""` | last rollup digest seen |

It fetches on a final seal, on a sequence gap, on reconnect or tab visibility,
and on the keyframe timer. See [repair.md](repair.md).

### `ms-reveal`

Mounts on the message element, has no targets and no actions, and needs one
stylesheet:

```erb
<%= stylesheet_link_tag "maquina_stream/reveal" %>
```

When a block's text grows, the tail that just arrived is wrapped in **one**
`<span data-ms-revealing>`, animated in, and unwrapped again on `animationend` —
so a block is plain text between frames and the DOM gains at most one extra live
node per block, not one per word.

| Value | Default | Meaning |
|---|---|---|
| `data-ms-reveal-duration-value` | `320` | milliseconds; writes `--ms-reveal-duration` |
| `data-ms-reveal-disabled-value` | `false` | markup without the animation |

Nothing animates when the message element has no `data-ms-streaming`, while the
tab is hidden, while suppressed, or under `prefers-reduced-motion: reduce` — the
last is answered in the controller as well as in CSS, because with
`animation: none` no `animationend` fires and a span wrapped anyway would never
be unwrapped.

Suppression is an event, not a method call. `ms-repair` dispatches `ms:suppress`
on the message element before a repair morph and `ms:resume` after it;
`ms-reveal` listens for both in `connect`. Suppression unwraps whatever is
mid-flight so the morph never sees reveal chrome, and resume re-baselines every
block to the text currently on screen — which is what keeps a repair from
re-revealing what the reader has already read.

### `ms-autoscroll`

Wrap whatever actually scrolls, and bind the three actions:

```erb
<div data-controller="ms-autoscroll"
     data-action="scroll->ms-autoscroll#track
                  wheel->ms-autoscroll#release
                  touchmove->ms-autoscroll#release"
     style="overflow-y: auto">
  <%= render @messages %>
</div>
```

For a page that scrolls as a whole:

```erb
<div data-controller="ms-autoscroll"
     data-ms-autoscroll-scroller-value="window"
     data-action="scroll@window->ms-autoscroll#track
                  wheel@window->ms-autoscroll#release
                  touchmove@window->ms-autoscroll#release">
```

| Value | Default | Meaning |
|---|---|---|
| `scroller` | `"self"` | `"self"` or `"window"` |
| `threshold` | `32` | how close to the bottom still counts as at the bottom, in px |
| `pinned` | `true` | current state, serialized so it survives a morph |

The rule the whole controller exists to keep: **it never scrolls unless it is
pinned, and only the reader can pin it.** Pinning is derived from position and
never remembered, so scrolling back to the bottom re-pins by the same rule that
unpinned you.

### `ms-link-safety`

Mount it on the container, not on each anchor: the anchors are model output,
their count is unbounded, and one delegated listener survives a repair morph
that replaces every one of them.

```erb
<div data-controller="ms-link-safety" data-action="click->ms-link-safety#intercept">
  <%= MaquinaStream.render(message) %>

  <dialog data-ms-link-safety-target="dialog" aria-labelledby="link-safety-title">
    <h3 id="link-safety-title"><%= t("maquina_stream.link_safety.title") %></h3>
    <p data-ms-link-safety-target="url"></p>
    <label>
      <input type="checkbox" data-ms-link-safety-target="remember">
      <%= t("maquina_stream.link_safety.always_allow") %>
    </label>
    <button type="button" data-action="ms-link-safety#confirm"><%= t("maquina_stream.link_safety.confirm") %></button>
    <button type="button" data-action="ms-link-safety#cancel"><%= t("maquina_stream.link_safety.cancel") %></button>
  </dialog>
</div>
```

| Value | Default | Meaning |
|---|---|---|
| `origin` | `""` | same-origin links are followed with no prompt |
| `bypass` | `false` | turns the guard off, for a host with its own interstitial |
| `rememberKey` | `"ms-link-safety.trusted"` | session-storage key for hosts the reader chose to trust |

Trust is kept in session storage, not local: trust granted mid-conversation
should not outlive the tab. The controller refuses anything outside `http:`,
`https:` and `mailto:` whatever the document says.

The allowlist is a function, not an attribute — an allowlist an injected
fragment can rewrite is not an allowlist:

```js
import { linkSafety } from "maquina_stream"
linkSafety.allow = (url) => url.hostname.endsWith("example.com")
```

`url` is a parsed `URL`. Returning true follows the link with no dialog.

### `ms-code`

Mounted by the renderer on a code block. Copy and download read the
`<pre hidden data-ms-code-source>` carrier, never the highlighted markup, so a
copy returns raw source rather than Rouge's spans.

| Value | Default | Meaning |
|---|---|---|
| `sourceSelector` | `"[data-ms-code-source]"` | late-bound, so a host with a different carrier need not fork the controller |
| `filename` | `""` | download name; otherwise derived from the language |

An unknown language downloads as `.txt` rather than guessing an extension.

### `ms-table`

Mounted by the renderer on the table wrapper. It reconstructs the table from the
DOM cell by cell using `textContent` — nothing here reads or produces HTML.

The engine renders its own control bar unless you turn the `table` controls off.
If you render your own:

```html
<div data-ms-table data-controller="ms-table">
  <button data-ms-control data-action="ms-table#copy" data-ms-table-format-param="markdown">…</button>
  <button data-ms-control data-action="ms-table#download" data-ms-table-format-param="csv">…</button>
  <button data-ms-control data-action="ms-table#toggleFullscreen">…</button>
  <table>…</table>
</div>
```

Formats are `markdown`, `csv` and `tsv`.

## Controls are inert while streaming

Two things make that true, and both are needed:

1. the message element carries `data-ms-streaming` while the message is open;
2. every control carries `data-ms-control`.

The base controller disables marked controls whenever the attribute is present
and re-enables them the moment the seal removes it, so the UI never offers half
a code block to copy. **Controls you render yourself must carry
`data-ms-control` too**, or they stay clickable mid-stream.

Turning controls off in configuration removes the buttons the renderer emits.
See [configuration.md](configuration.md).

## Events

Every controller dispatches through Stimulus with the `ms` prefix, so listen for
`ms:<name>` on or above the element.

| Event | Detail | From |
|---|---|---|
| `ms:copied` | `{length, fallback?}` | any copy control |
| `ms:copy-failed` | `{text}` | any copy control |
| `ms:downloaded` | `{filename}` | any download control |
| `ms:refused` | `{reason: "streaming"}` | a control clicked while the message is open |
| `ms:repaired` | `{reason, blocks}` | `ms-repair` |
| `ms:repair-failed` | `{reason, error}` | `ms-repair` |
| `ms:rendered` | `{controller}` | a deferred renderer |
| `ms:render-failed` | `{controller, error}` | a deferred renderer |
| `ms:fullscreen` | `{fullscreen}` | `ms-table` |
| `ms:autoscroll` | `{pinned}` | `ms-autoscroll` |
| `ms:link-prompted` | `{href}` | `ms-link-safety` |
| `ms:link-followed` | `{href}` | `ms-link-safety` |
| `ms:link-cancelled` | `{href}` | `ms-link-safety` |
| `ms:link-refused` | `{href}` | `ms-link-safety` |

`ms:suppress` and `ms:resume` are dispatched on the message element as plain
`CustomEvent`s, without the prefix, and do not bubble.

## Locale

Labels follow `I18n.locale`, like any Rails app. `config.locale` is the engine's
own fallback for a host that has expressed no preference. Spanish and English
both ship complete.

## Treat everything the DOM says as untrusted

No `ms-` controller assigns a DOM-derived or payload-derived string as HTML. The
server sanitizer allows `data-controller`, restricted to the `ms-` namespace,
but it cannot tell a controller our post-pass emitted from one an injected
fragment asked for. A controller of your own that reads values out of rendered
message markup should hold the same line. See [security.md](security.md).
