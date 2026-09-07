// Harness entrypoint. A host does exactly this: start Stimulus, then hand the
// application to the engine so it registers its own identifiers.
import "@hotwired/turbo-rails"
import { Application } from "@hotwired/stimulus"
import { registerMaquinaStreamControllers } from "maquina_stream"

const application = Application.start()
application.debug = true
window.Stimulus = application

registerMaquinaStreamControllers(application)
