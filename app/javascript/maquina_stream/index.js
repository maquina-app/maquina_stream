// maquina_stream — Stimulus entrypoint.
//
// The engine registers its own controllers rather than relying on the host's
// eager-load glob: the identifiers are part of the DOM contract
// (docs/api-surface.md) and must not depend on where a host puts its files.
//
//   import { Application } from "@hotwired/stimulus"
//   import { registerMaquinaStreamControllers } from "maquina_stream"
//
//   const application = Application.start()
//   registerMaquinaStreamControllers(application)
//
// Nothing here imports a third-party library. The controllers that do —
// `ms-diagram`, `ms-math` — import lazily at render time, per the NoBuild rule
// in CLAUDE.md.

import MsAutoscrollController from "maquina_stream/controllers/ms_autoscroll_controller"
import MsCodeController from "maquina_stream/controllers/ms_code_controller"
import MsLinkSafetyController from "maquina_stream/controllers/ms_link_safety_controller"
import MsTableController from "maquina_stream/controllers/ms_table_controller"

export { linkSafety } from "maquina_stream/controllers/ms_link_safety_controller"

// Identifier → controller. The identifiers are fixed by docs/api-surface.md.
export const controllers = {
  "ms-autoscroll": MsAutoscrollController,
  "ms-code": MsCodeController,
  "ms-link-safety": MsLinkSafetyController,
  "ms-table": MsTableController
}

export function registerMaquinaStreamControllers(application) {
  Object.entries(controllers).forEach(([identifier, controller]) => {
    application.register(identifier, controller)
  })

  // Turbo caches the page as the user left it. A controller that mutated the
  // DOM rolls that back here rather than in `disconnect`, which also runs on
  // ordinary navigation. See betterstimulus.com, "global teardown".
  document.addEventListener("turbo:before-cache", () => {
    application.controllers.forEach((controller) => {
      if (typeof controller.teardown === "function") controller.teardown()
    })
  })

  return application
}

export default registerMaquinaStreamControllers
