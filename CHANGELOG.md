# Changelog

## Unreleased — 0.1.0

First working version. The engine renders a streaming markdown buffer to HTML on
the server and broadcasts it over Turbo Streams; only rendered HTML reaches the
browser.

- **Render pipeline** — `maquina_remend` → commonmarker with sourcepos →
  a single Nokogiri post-pass → sanitizer. Pure: it runs outside a Rails request
  with no stubbing, asserted in a subprocess with no application booted.
- **Sealing and broadcast** — blocks seal behind a configurable lag, ids are
  index-derived, and a sealed block is never re-broadcast. The seal pointer
  stops at an unresolved link reference definition, because a definition
  rewrites links arbitrarily far above it.
- **Repair** — a windowed manifest of block digests, four triggers, and a silent
  morph of only the blocks that differ. Deltas are an optimization; correctness
  lives here.
- **Interaction** — copy, download, table export, fullscreen, link safety and
  autoscroll, every control individually disableable and inert while streaming.
- **Client-deferred renderers** — diagrams and math render in the browser from
  one JSON payload per leaf node, with split ownership across morphs.
- **Registries** — elements, custom tags and fences, the last with server,
  passthrough and client strategies.
- **Text direction per block**, decided by the first strong character. Fences
  carrying bidi control characters are pinned, against Trojan Source.
- **History** — sealed messages are frozen and fragment-cached by buffer digest;
  1942x on a warm cache.
- Spanish default locale, English secondary. No Node build step anywhere.

Not yet released: `maquina_remend` is still a path reference.
