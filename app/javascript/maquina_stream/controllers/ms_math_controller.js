import MsDeferredController from "maquina_stream/controllers/ms_deferred_controller"

// `ms-math` — KaTeX, with trust disabled.
//
// `trust: false` refuses \htmlClass, \includegraphics and \href, all of which
// take attacker-controlled strings straight into the DOM. `throwOnError: false`
// keeps a malformed formula from taking the message down; ms-deferred's error
// path handles the rest.
export default class extends MsDeferredController {
  static library = null

  async library() {
    if (!this.constructor.library) {
      const katex = await import("katex")
      this.constructor.library = katex.default ?? katex
    }

    return this.constructor.library
  }

  async draw(payload) {
    const katex = await this.library()

    return katex.renderToString(String(payload.source ?? ""), {
      displayMode: payload.display !== false,
      throwOnError: false,
      trust: false,
      strict: "ignore",
      output: "html"
    })
  }
}
