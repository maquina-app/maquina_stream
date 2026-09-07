import ApplicationController from "maquina_stream/controllers/application_controller"

// `ms-code` — copy and download a rendered code block.
//
// The DOM contract (docs/api-surface.md) fixes the shape:
//
//   <div data-ms-code data-ms-code-lang="ruby" data-controller="ms-code">
//     <button data-ms-control data-action="ms-code#copy">…</button>
//     <button data-ms-control data-action="ms-code#download">…</button>
//     <pre><code>…highlighted…</code></pre>
//     <pre hidden data-ms-code-source>…raw source…</pre>
//   </div>
//
// Copy and download read the `data-ms-code-source` carrier, never the
// highlighted markup. The carrier is a `<pre hidden>`, not a script tag: its
// content is ordinary escaped text, so `textContent` is the whole story and
// nothing has to be unescaped. Reading the highlighted `<code>` instead would
// hand back Rouge's span soup collapsed into text.
export default class extends ApplicationController {
  // Late-bound so a host with a different carrier does not have to fork the
  // controller. Both are scoped to `this.element`.
  static values = {
    sourceSelector: { type: String, default: "[data-ms-code-source]" },
    filename: { type: String, default: "" }
  }

  static targets = ["source"]

  // Extension per language. An unknown language downloads as `.txt` rather
  // than guessing: a wrong extension is worse than a generic one.
  static extensions = {
    bash: "sh", c: "c", cpp: "cpp", csharp: "cs", css: "css", diff: "diff",
    elixir: "ex", erb: "erb", go: "go", haml: "haml", html: "html",
    java: "java", javascript: "js", js: "js", json: "json", jsx: "jsx",
    kotlin: "kt", markdown: "md", md: "md", python: "py", py: "py",
    ruby: "rb", rb: "rb", rust: "rs", scss: "scss", sh: "sh", shell: "sh",
    sql: "sql", swift: "swift", toml: "toml", ts: "ts", tsx: "tsx",
    typescript: "ts", xml: "xml", yaml: "yml", yml: "yml", zsh: "sh"
  }

  connect() {
    this.startStreamGuard()
  }

  disconnect() {
    this.stopStreamGuard()
  }

  // ------------------------------------------------------------------ actions

  copy(event) {
    if (this.refuseWhileStreaming(event)) return
    this.copyText(this.source)
  }

  download(event) {
    if (this.refuseWhileStreaming(event)) return
    this.downloadText(this.source, this.downloadName, "text/plain")
  }

  // ------------------------------------------------------------------ reading

  get sourceElement() {
    if (this.hasSourceTarget) return this.sourceTarget
    try {
      return this.element.querySelector(this.sourceSelectorValue)
    } catch {
      // The selector is a DOM-derived string; a malformed one must not throw
      // out of an event handler.
      return null
    }
  }

  // Untrusted text. It is only ever handed to the clipboard, to a Blob, or to
  // a textarea's `value` — never assigned as HTML.
  get source() {
    return this.sourceElement?.textContent ?? ""
  }

  // The DOM contract writes the language as `data-ms-code-lang`, which is one
  // suffix short of a Stimulus value (`data-ms-code-lang-value`). It is read as
  // a plain attribute on purpose so the pipeline's output needs no change.
  get language() {
    return (this.element.getAttribute("data-ms-code-lang") || "").trim().toLowerCase()
  }

  get extension() {
    return this.constructor.extensions[this.language] || "txt"
  }

  get downloadName() {
    if (this.filenameValue.length) return this.filenameValue
    const stem = this.language.replace(/[^a-z0-9_-]/g, "") || "snippet"
    return `${stem}.${this.extension}`
  }
}
