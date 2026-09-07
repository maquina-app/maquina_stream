# Interaction layer

The Stimulus controllers, the markup they bind to, and how a host turns any of
it off. Identifiers are fixed by `docs/api-surface.md`.

## Registering

The engine registers its own controllers; it does not rely on the host's
eager-load glob, because the identifiers are part of the DOM contract.

```js
import { Application } from "@hotwired/stimulus"
import { registerMaquinaStreamControllers } from "maquina_stream"

const application = Application.start()
registerMaquinaStreamControllers(application)
```

Pins are appended to the host's importmap by the engine. Nothing is bundled,
and no controller imports a third-party library at load time.

## What the renderer emits, and what the host must add

The renderer emits everything the controllers need **inside a message**:
`ms-code` and its controls on a code block, `ms-table` and its controls on a
table wrapper. Two things are the host's, because they are page-level rather
than message-level:

```erb
<%# link safety wraps the message; one delegated listener survives a morph %>
<div data-controller="ms-link-safety" data-action="click->ms-link-safety#intercept">
  <%= @message_html %>
  <dialog data-ms-link-safety-target="dialog">
    <p data-ms-link-safety-target="url"></p>
    <label><input type="checkbox" data-ms-link-safety-target="remember"> …</label>
    <button type="button" data-action="ms-link-safety#confirm">Continuar</button>
    <button type="button" data-action="ms-link-safety#cancel">Cancelar</button>
  </dialog>
</div>

<%# autoscroll wraps whatever actually scrolls %>
<div data-controller="ms-autoscroll"
     data-action="scroll->ms-autoscroll#track
                  wheel->ms-autoscroll#release
                  touchmove->ms-autoscroll#release">
  <%= @conversation %>
</div>
```

A working example of both is `test/dummy/app/views/harness/show.html.erb`.

**Mounting a controller without its actions is silent.** Nothing errors; the
controller simply never hears anything. Both of these were wired wrongly first
time and only the browser caught it — which is why the harness exists.

## Streaming chrome is the host's one attribute

Blocks carry no streaming state. The message element does, and everything else
is derived:

```erb
<div id="ms-msg-<%= message.maquina_stream_id %>"
     <%= "data-ms-streaming" if message.maquina_stream_open? %>>
  <%= @message_html %>
</div>
```

```css
[data-ms-streaming] > [data-ms-block]:last-child::after { /* caret */ }
```

`ms-reveal` reads the same attribute from JavaScript: a message without it is
sealed, and a sealed message does not animate.

One attribute to keep correct instead of one per block — and, more importantly,
one that cannot drift: a block's bytes are exactly what its digest covers, so
two tabs holding the same content hold the same DOM. See `docs/api-surface.md`
for why this changed.

## The reveal

`ms-reveal` mounts on the message element and needs one stylesheet, which the
host loads next to the theme:

```erb
<%= stylesheet_link_tag "maquina_stream/reveal" %>
```

It has no targets and no actions. When a block's text grows, the tail that just
arrived is wrapped in **one** `<span data-ms-revealing>`, that span is animated
in, and on `animationend` it is unwrapped again — so a block is plain text
between frames, and the DOM gains at most one live extra node per block rather
than one per word.

Two values, both optional:

| Value | Default | Meaning |
|---|---|---|
| `data-ms-reveal-duration-value` | the stylesheet's `320ms` | writes `--ms-reveal-duration` |
| `data-ms-reveal-disabled-value` | `false` | markup without the animation |

Nothing animates when the message element has no `data-ms-streaming`, while the
tab is hidden, while suppressed, or under `prefers-reduced-motion: reduce` —
the last one is answered in the controller as well as in CSS, because with
`animation: none` no `animationend` fires and a span wrapped anyway would never
be unwrapped.

### Suppression is an event, not a method call

`ms-repair` dispatches `ms:suppress` on the message element before a repair
morph and `ms:resume` after it. `ms-reveal` listens for both; it exposes no
public method for it, and `ms-repair` holds no reference to it. Suppression
unwraps whatever is mid-flight, so the morph never sees reveal chrome, and
resume re-baselines every block to the text currently on screen — which is what
keeps a repair from re-revealing what the reader has already read.

The listeners are wired in `connect`, not through `data-action`, because the
markup a host renders (`docs/api-surface.md`) carries `data-controller` and no
actions. A reveal that needed one more attribute would silently never suppress.

### Why not a CSS mask

Phase 0's strategy C masked the whole block with a horizontal gradient whose
edge sat at `revealed / total` **characters**. A character fraction is a
horizontal position only while a block occupies one line. Measured on a
three-line block, each line's text ended at ~94% of the block's width, so an
edge at 75% hid the last fifth of *every* line — including lines read seconds
earlier — and swept them back in on the next frame. That is the flash the
review saw on a block's first few lines, fading as the fraction approached 100%.

No gradient stop fixes that: the geometry is wrong, not the easing. Animating
the newly arrived text itself is reading-order correct by construction, because
there is no mapping from characters to pixels anywhere in it.

### Verified in a browser

Against `/harness/reveal` in Chromium, on a block wrapping over **10** visual
lines. The measurements are per animation — which element animated, the text it
held, and the box it occupied — because the mask had a single animated element
and "something animated" could not have caught the bug above.

- **Open message reveals.** 12 consecutive deltas, 12 `animationstart` events,
  each on a `span[data-ms-revealing]` and never on the block. Every span's text
  was exactly the delta that had just arrived, every span's box sat at or below
  the last line that existed before it, and the client rects of all preceding
  lines were identical before and after each frame. The block's node count was
  7 before the 12 frames and 7 after them.
- **Sealed message does not animate.** With `data-ms-streaming` removed: 5
  appends, **0** animation events, 0 running animations, 0 spans, full text
  present.
- **Suppression.** A frame mid-animation, then `ms:suppress` → the in-flight
  span is unwrapped immediately (0 spans, 0 running animations) with its text
  intact. Text arriving while suppressed: 0 animations, text intact. After
  `ms:resume` the next delta animates one span holding **only** that delta —
  neither the text that arrived during suppression nor anything before it.
- **`prefers-reduced-motion: reduce`.** Emulated at the browser level, message
  still open: 6 appends, **0** animation events, `document.getAnimations()`
  empty, 0 spans, block opacity 1, filter `none`, and all six deltas present.

## The allowlist is a function, not an attribute

```js
import { linkSafety } from "maquina_stream"
linkSafety.allow = (url) => url.hostname.endsWith("example.com")
```

An allowlist in a data attribute is one an injected fragment can rewrite.

## Configuration

Every control is individually disableable, and all of them at once:

```ruby
MaquinaStream.configure do |c|
  c.controls = false                                  # nothing at all
  c.controls = {code: {copy: true, download: false}}  # one at a time
end
```

When a group is fully off the renderer emits no controller attribute either —
a controller with nothing to drive is cost on every frame.

## Locale

Labels follow `I18n.locale`, like any Rails app. `config.locale` is the
engine's own default for a host that has expressed no preference. Spanish and
English ship complete, and `locales_test.rb` fails the build if a key exists in
one and not the other.

## Verified in a browser

Against the harness, in Chromium:

- 17 controls reachable by keyboard, every one with an accessible name and a
  visible focus ring.
- Copy returns the **raw** source from the `<pre hidden data-ms-code-source>`
  carrier, not Rouge's span markup.
- Table copy reconstructs markdown from the DOM with quotes and commas intact.
- The link dialog intercepts, traps focus, and restores focus to the link that
  opened it.
- Autoscroll follows while pinned, releases the moment the reader scrolls up,
  **holds position through further frames**, and re-sticks only when the reader
  returns to the bottom themselves.

## Controls are inert while streaming

Two things make that true, and both are needed:

1. The message element carries `data-ms-streaming` while the message is open —
   the host stamps it from `maquina_stream_open?`.
2. Every control the engine renders carries `data-ms-control`.

`ApplicationController` disables the marked controls whenever the attribute is
present, and re-enables them the moment the seal removes it. Verified in a
browser: 6/6 controls disabled in a streaming message, 0/6 in a sealed one, and
sealing re-enables them live.

A host rendering its own controls should mark them `data-ms-control` too;
without it they stay clickable mid-stream.

## Automated accessibility audit

axe-core 4.10.2, WCAG 2.0/2.1 A and AA, run in Chromium against the harness:

| Page / state | Violations |
|---|---|
| `/harness` | **0** (19 rule groups passing) |
| `/harness` with the link dialog open | **0** |
| `/history` | **0** |

The dialog is audited *while open*, because that is the state a modal usually
fails in.

**This is not the screen reader pass.** axe finds missing names, roles, contrast
and structure; it cannot tell you whether what gets announced makes sense, and
it does not know that "Copiar como CSV" read aloud after "Copiar como Markdown"
needs to be distinguishable. It narrows what a person has to check; it does not
replace them.

## Not verified, and why

- **The screen reader pass.** No agent in this project can drive VoiceOver, NVDA
  or JAWS, and asserting that an `aria-label` exists is not the same as hearing
  what gets announced. Open the harness and listen.
- **Clipboard in Firefox and Safari.** Chromium is covered, *including the
  insecure-context fallback*: with `navigator.clipboard` removed and
  `isSecureContext` false, `copyText` falls through to `execCommand`, copies the
  source exactly, and leaves no stray textarea. What remains is the other two
  engines, which need a person or a CI matrix.

Boot the harness:

```sh
cd test/dummy && bundle exec puma -p 3001 config.ru
# http://localhost:3001/harness
```
