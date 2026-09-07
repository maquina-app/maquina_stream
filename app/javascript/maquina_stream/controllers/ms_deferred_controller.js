import ApplicationController from "maquina_stream/controllers/application_controller"

// `ms-deferred` — the base class for a renderer that runs in the browser.
//
// Subclasses (`ms-diagram`, `ms-math`) supply two things: how to import their
// library, and how to turn a payload into markup. Everything else — when to
// render, what to do on a repair morph, how to fail, and what may reach the
// DOM — is decided here, once.
//
//   <div data-controller="ms-diagram"
//        data-ms-diagram-payload-value='{"source":"graph TD…"}'>
//     <div data-ms-diagram-target="output" data-turbo-permanent>…</div>
//   </div>
//
// Split ownership, from docs/deferred-renderers.md: the payload attribute is server
// state and belongs to morph; the output element is client state and belongs to
// this controller. A repair morph that leaves the payload byte-identical fires
// no value-changed callback, so it triggers no re-render and no flicker — which
// is the property Phase 4 depends on.
export default class extends ApplicationController {
  static targets = ["output"]

  static values = {
    payload: Object,
    // Rendering is deferred until the element is on screen. A conversation
    // scrolled back through hundreds of messages should not render hundreds of
    // diagrams nobody is looking at.
    eager: { type: Boolean, default: false }
  }

  connect() {
    this.connected = true

    if (this.eagerValue) return this.render()

    this.observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) this.render()
    }, { rootMargin: "200px" })

    this.observer.observe(this.element)
  }

  disconnect() {
    this.connected = false
    this.observer?.disconnect()
    this.observer = null
  }

  // The payload changed under a morph: re-render, but only because it really
  // changed. Stimulus only fires this when the attribute's value differs.
  //
  // The `connected` guard is the whole of the lazy load, and it is not
  // defensive coding. Stimulus invokes every value-changed callback ONCE while
  // the context connects, before `connect()` runs, and it passes as `previous`
  // the value type's DEFAULT — `{}` for an Object — never `undefined`. So a
  // guard written as `previous === undefined` never fires: the initial
  // invocation reads as a real change, resets `rendered` and calls `render()`.
  //
  // That is exactly what happened. With mermaid and katex pinned in the dummy
  // app, Chromium fetched both at scrollY 0 with the blocks 4,500px down the
  // page. `library()` is lazy and the observer is correct; this callback was
  // calling past both of them.
  payloadValueChanged(payload, previous) {
    if (!this.connected) return
    if (JSON.stringify(payload) === JSON.stringify(previous)) return

    this.rendered = false
    this.render()
  }

  async render() {
    if (this.rendered) return
    if (!this.hasPayload) return

    this.rendered = true

    try {
      const markup = await this.draw(this.payloadValue)
      this.replaceOutput(markup)
    } catch (error) {
      this.fail(error)
    }
  }

  get hasPayload() {
    return this.payloadValue && Object.keys(this.payloadValue).length > 0
  }

  // ------------------------------------------------------------- subclass API

  // Import the library. Called once, lazily, and only when there is something
  // to draw — a page with no deferred content loads no renderer at all.
  async library() {
    throw new Error("ms-deferred subclasses must implement library()")
  }

  // Turn a payload into markup. Returns a string or a Node.
  async draw(_payload) {
    throw new Error("ms-deferred subclasses must implement draw()")
  }

  // ------------------------------------------------------------------ output

  // Nothing a renderer produces is trusted. The server sanitized the document,
  // and this sanitizes again on the way in: the payload is model output, the
  // library is third-party, and neither is a reason to skip the check. See
  // CLAUDE.md — renderer output gets sanitized client-side even though the
  // server already sanitized the document.
  replaceOutput(markup) {
    if (!this.hasOutputTarget) return

    const safe = this.sanitize(markup)
    this.outputTarget.replaceChildren(safe)
    this.notify("rendered", { controller: this.identifier })
  }

  sanitize(markup) {
    const template = document.createElement("template")

    if (markup instanceof Node) {
      template.content.append(markup)
    } else {
      template.innerHTML = String(markup)
    }

    this.scrub(template.content)
    return template.content
  }

  // An allowlist, not a blocklist: anything not named here loses its markup and
  // keeps its text. Scripts and foreign-content subtrees go entirely.
  scrub(root) {
    const allowed = this.constructor.allowedElements
    const dropWithContent = this.constructor.droppedElements

    for (const node of [...root.querySelectorAll("*")]) {
      const name = node.tagName.toLowerCase()

      if (dropWithContent.has(name)) {
        node.remove()
        continue
      }

      for (const attribute of [...node.attributes]) {
        if (!this.attributeAllowed(name, attribute)) node.removeAttribute(attribute.name)
      }

      if (!allowed.has(name)) node.replaceWith(...node.childNodes)
    }
  }

  attributeAllowed(_element, attribute) {
    const name = attribute.name.toLowerCase()

    if (name.startsWith("on")) return false
    if (name === "style") return false
    if (["href", "xlink:href", "src", "srcdoc", "formaction"].includes(name)) {
      return name === "href" && /^(https?:|mailto:|#)/i.test(attribute.value.trim())
    }

    return this.constructor.allowedAttributes.has(name)
  }

  static allowedElements = new Set([
    "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
    "text", "tspan", "marker", "defs", "symbol", "use", "title", "desc", "foreignObject",
    "div", "span", "p", "br", "sub", "sup", "table", "tbody", "tr", "td", "annotation",
    "semantics", "mrow", "mi", "mn", "mo", "ms", "mtext", "mfrac", "msqrt", "mroot",
    "msub", "msup", "msubsup", "munder", "mover", "munderover", "mtable", "mtr", "mtd",
    "mspace", "mpadded", "mphantom", "menclose", "mstyle", "math", "a"
  ])

  static droppedElements = new Set([
    "script", "iframe", "object", "embed", "link", "meta", "base", "form",
    "input", "button", "textarea", "select", "audio", "video", "animate",
    "animatetransform", "set", "handler", "listener"
  ])

  static allowedAttributes = new Set([
    "class", "id", "width", "height", "viewbox", "d", "fill", "stroke",
    "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
    "transform", "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry",
    "points", "text-anchor", "dominant-baseline", "font-size", "font-family",
    "font-weight", "opacity", "fill-opacity", "stroke-opacity", "marker-end",
    "marker-start", "preserveaspectratio", "aria-label", "aria-hidden", "role",
    "mathvariant", "displaystyle", "scriptlevel", "href", "dir", "lang",
    "colspan", "rowspan", "columnalign", "rowalign", "open", "close", "separator"
  ])

  // ------------------------------------------------------------------- errors

  // A broken payload never breaks the message. The block degrades to something
  // readable and says why, and the rest of the message is untouched.
  fail(error) {
    if (!this.hasOutputTarget) return

    const fallback = document.createElement("div")
    fallback.setAttribute("data-ms-deferred-error", "")
    fallback.setAttribute("role", "note")

    const message = document.createElement("p")
    message.textContent = this.errorLabel

    // The source is the export fallback, and it is the same one for every
    // deferred renderer: show what the model actually wrote. See
    // docs/deferred-renderers.md.
    const source = document.createElement("pre")
    source.textContent = this.payloadValue?.source ?? ""

    fallback.append(message, source)
    this.outputTarget.replaceChildren(fallback)
    this.notify("render-failed", { controller: this.identifier, error: String(error) })
  }

  // The server renders the label, translated, into the data attribute. This
  // fallback is only reached when a host renders the block without one, so it
  // is the language of last resort rather than the engine's default locale —
  // JavaScript cannot read I18n, and hardcoding Spanish here would show Spanish
  // to a host that never asked for it.
  get errorLabel() {
    return this.element.dataset.msDeferredErrorLabel || "This block could not be rendered."
  }
}
