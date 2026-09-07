# frozen_string_literal: true

# Harness only. The engine appends its own pins to this via its importmap
# initializer, exactly as a real host would receive them.
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"

# Host pins for the client-deferred renderers. A real host adds these; the
# engine never pins a third-party library (see config/importmap.rb).
#
# `preload: false` is load-bearing, not cosmetic. importmap-rails preloads by
# default, which would emit a <link rel="modulepreload"> and fetch both
# libraries on every page — exactly the cost the lazy import inside
# `ms-deferred#library()` exists to avoid. Pinned to an exact version: NoBuild
# means no lockfile, so the version lives here and nowhere else.
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/+esm", preload: false
pin "katex", to: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.mjs", preload: false
