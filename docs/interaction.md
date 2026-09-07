# Interaction layer

Four Stimulus controllers, the markup they bind to, and how a host turns any of
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

## Not verified, and why

- **The screen reader pass.** No agent in this project can drive VoiceOver, NVDA
  or JAWS, and asserting that an `aria-label` exists is not the same as hearing
  what gets announced. Open the harness and listen.
- **Clipboard in Firefox and Safari**, including the insecure-context fallback.
  Chromium is covered above; the other two need a person or a CI matrix.

Boot the harness:

```sh
cd test/dummy && bundle exec puma -p 3001 config.ru
# http://localhost:3001/harness
```
