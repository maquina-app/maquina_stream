import MsDeferredController from "maquina_stream/controllers/ms_deferred_controller"

// `ms-diagram` — Mermaid, rendered in the browser, in strict security mode.
//
// The library is imported the first time a diagram is actually about to draw,
// so a page with no diagrams never fetches it. Pinned by version: NoBuild means
// no lockfile, so the version lives in the importmap and nowhere else.
export default class extends MsDeferredController {
  static values = {
    ...MsDeferredController.values,
    theme: { type: String, default: "default" }
  }

  static library = null

  async library() {
    // securityLevel "strict" is the point: it disables click handlers and
    // inline HTML inside diagram source, which is model output.
    if (!this.constructor.library) {
      const mermaid = await import("mermaid")
      mermaid.default.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: this.themeValue
      })
      this.constructor.library = mermaid.default
    }

    return this.constructor.library
  }

  async draw(payload) {
    const mermaid = await this.library()
    const id = `ms-mermaid-${Math.random().toString(36).slice(2)}`
    const { svg } = await mermaid.render(id, String(payload.source ?? ""))

    // Sanitized by ms-deferred on the way in, strict mode or not.
    return svg
  }
}
