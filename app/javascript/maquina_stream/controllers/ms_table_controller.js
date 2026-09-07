import ApplicationController from "./application_controller"

// `ms-table` — copy and download a rendered table as markdown, CSV or TSV, and
// toggle fullscreen.
//
// The render post-pass already mounts this controller on the table wrapper:
//
//   <div data-ms-table data-controller="ms-table">
//     <table>…</table>
//   </div>
//
// It emits no controls, so a host adds them inside the wrapper:
//
//   <button data-ms-control data-action="ms-table#copy"
//           data-ms-table-format-param="markdown">…</button>
//   <button data-ms-control data-action="ms-table#download"
//           data-ms-table-format-param="csv">…</button>
//   <button data-ms-control data-action="ms-table#toggleFullscreen">…</button>
//
// The table is reconstructed from the DOM, cell by cell, using `textContent`.
// Nothing here reads or produces HTML.
export default class extends ApplicationController {
  static targets = ["table"]

  static classes = ["fullscreen"]

  static values = {
    tableSelector: { type: String, default: "table" },
    filename: { type: String, default: "table" },
    format: { type: String, default: "markdown" },
    fullscreen: { type: Boolean, default: false }
  }

  static mimes = {
    markdown: "text/markdown",
    csv: "text/csv",
    tsv: "text/tab-separated-values"
  }

  static extensions = { markdown: "md", csv: "csv", tsv: "tsv" }

  connect() {
    this.startStreamGuard()
  }

  disconnect() {
    this.stopStreamGuard()
  }

  // ------------------------------------------------------------------ actions

  copy(event) {
    if (this.refuseWhileStreaming(event)) return
    this.copyText(this.serialize(this.formatFrom(event)))
  }

  download(event) {
    if (this.refuseWhileStreaming(event)) return

    const format = this.formatFrom(event)
    const extension = this.constructor.extensions[format]
    this.downloadText(
      this.serialize(format),
      `${this.filenameValue}.${extension}`,
      this.constructor.mimes[format]
    )
  }

  toggleFullscreen(event) {
    if (this.refuseWhileStreaming(event)) return
    this.fullscreenValue = !this.fullscreenValue
  }

  exitFullscreen() {
    this.fullscreenValue = false
  }

  // The Fullscreen API is not available in every embedding context (an iframe
  // without `allowfullscreen`, for one), so the class is the source of truth
  // and the native call is best-effort on top of it.
  fullscreenValueChanged(fullscreen, previous) {
    if (this.hasFullscreenClass) {
      this.element.classList.toggle(this.fullscreenClass, fullscreen)
    }

    if (previous === undefined) return

    if (fullscreen) {
      this.element.requestFullscreen?.().catch(() => {})
    } else if (document.fullscreenElement === this.element) {
      document.exitFullscreen?.().catch(() => {})
    }

    this.notify("fullscreen", { fullscreen })
  }

  // Turbo caches the page as it stands. A table left fullscreen would come
  // back that way on a restore visit.
  teardown() {
    this.fullscreenValue = false
  }

  // ------------------------------------------------------------------ reading

  formatFrom(event) {
    const requested = event?.params?.format || this.formatValue
    return this.constructor.extensions[requested] ? requested : "markdown"
  }

  get tableElement() {
    if (this.hasTableTarget) return this.tableTarget
    try {
      return this.element.querySelector(this.tableSelectorValue)
    } catch {
      return null
    }
  }

  // `[headerRow, ...bodyRows]`, every cell a plain string. `rowSpan`/`colSpan`
  // are not expanded: markdown tables have no such thing, and the pipeline
  // never produces them.
  get rows() {
    const table = this.tableElement
    if (!table) return []

    return Array.from(table.rows).map((row) =>
      Array.from(row.cells).map((cell) => cell.textContent.trim())
    )
  }

  // --------------------------------------------------------------- serializing

  serialize(format) {
    const rows = this.rows
    if (!rows.length) return ""

    switch (format) {
      case "csv": return this.delimited(rows, ",")
      case "tsv": return this.delimited(rows, "\t")
      default: return this.markdown(rows)
    }
  }

  // RFC 4180. A cell is quoted when it contains the separator, a double quote,
  // CR or LF; embedded quotes are doubled. Applied to tabs too, so a TSV cell
  // holding a tab or a newline still round-trips through any parser that reads
  // RFC 4180 with a tab delimiter.
  delimited(rows, separator) {
    const width = Math.max(...rows.map((row) => row.length))

    return rows
      .map((row) => {
        const padded = Array.from({ length: width }, (_, i) => row[i] ?? "")
        return padded.map((cell) => this.quote(cell, separator)).join(separator)
      })
      .join("\r\n")
  }

  quote(cell, separator) {
    const needsQuotes =
      cell.includes(separator) || cell.includes('"') || cell.includes("\n") || cell.includes("\r")
    return needsQuotes ? `"${cell.replace(/"/g, '""')}"` : cell
  }

  // GFM pipe table. `|` is escaped as `\|` — the only escape GFM defines
  // inside a cell — and a newline becomes `<br>`, which is what GFM itself
  // uses, since a pipe table row cannot span lines.
  markdown(rows) {
    const width = Math.max(...rows.map((row) => row.length))
    const [header, ...body] = rows
    const line = (row) => {
      const padded = Array.from({ length: width }, (_, i) => row[i] ?? "")
      return `| ${padded.map((cell) => this.escapePipes(cell)).join(" | ")} |`
    }

    const separator = `| ${Array.from({ length: width }, () => "---").join(" | ")} |`
    return [line(header), separator, ...body.map(line)].join("\n")
  }

  escapePipes(cell) {
    return cell.replace(/\\/g, "\\\\").replace(/\|/g, "\\|").replace(/\r?\n/g, "<br>")
  }
}
