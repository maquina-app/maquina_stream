# frozen_string_literal: true

# Appended to the host's importmap by `MaquinaStream::Engine`.
#
# The engine pins only its own source. `@hotwired/stimulus` is the host's pin —
# an engine that pinned it would win or lose a version fight with the app for
# no reason. NoBuild: nothing here is compiled, bundled or fetched from npm.
pin "maquina_stream", to: "maquina_stream/index.js"
pin_all_from MaquinaStream::Engine.root.join("app/javascript/maquina_stream/controllers"),
             under: "maquina_stream/controllers"
