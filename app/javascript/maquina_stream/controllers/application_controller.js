import { Controller } from "@hotwired/stimulus"

// Base class for every `ms-` controller.
//
// Two things live here because every controller needs them and neither belongs
// in a single one:
//
//   1. `streaming` — the one signal that makes controls inert while a message
//      is still being written. See docs/interaction.md.
//   2. `copyText` / `downloadText` — clipboard and download plumbing, including
//      the insecure-context clipboard fallback.
//
// Nothing here ever assigns a DOM-derived or payload-derived string as HTML.
// Per docs/sanitizer.md the sanitizer cannot tell our attributes from injected
// ones, so every value a controller reads is untrusted input.
export default class ApplicationController extends Controller {
  // ---------------------------------------------------------------- streaming

  // The message element. The DOM contract fixes `#ms-msg-<sid>`; hosts that
  // wrap rendered output themselves can mark it with `data-ms-message`.
  get messageElement() {
    return this.element.closest("[data-ms-message]") || this.element.closest("[id^='ms-msg-']")
  }

  // A message is open exactly while its tail block carries `data-ms-caret`.
  // The post-pass emits the caret only in `:streaming` mode and only on the
  // last block, and seal re-renders in `:static` mode, which removes it. There
  // is no second source of truth and no client-held "is streaming" flag that
  // can fall out of sync with the server.
  get streaming() {
    const message = this.messageElement
    if (!message) return false
    return Boolean(message.querySelector("[data-ms-caret]"))
  }

  // Controls opt in by carrying `data-ms-control`. They are disabled while the
  // message streams so the UI never offers half a code block to copy.
  startStreamGuard() {
    this.syncStreamGuard()
    if (!this.messageElement) return

    this.streamGuardObserver = new MutationObserver(() => this.syncStreamGuard())
    this.streamGuardObserver.observe(this.messageElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["data-ms-caret"]
    })
  }

  stopStreamGuard() {
    this.streamGuardObserver?.disconnect()
    this.streamGuardObserver = null
  }

  syncStreamGuard() {
    const streaming = this.streaming
    this.element.querySelectorAll("[data-ms-control]").forEach((control) => {
      control.disabled = streaming
      control.setAttribute("aria-disabled", String(streaming))
    })
  }

  // Every public action that touches the clipboard, the filesystem or the
  // layout starts with this. The observer above is a convenience; this is the
  // guarantee.
  refuseWhileStreaming(event) {
    if (!this.streaming) return false
    event?.preventDefault()
    this.notify("refused", { reason: "streaming" })
    return true
  }

  // ---------------------------------------------------------------- clipboard

  // `navigator.clipboard` is undefined in an insecure context — plain HTTP on
  // anything but localhost — which is exactly where this engine gets demoed.
  // The fallback is a throwaway textarea plus `document.execCommand("copy")`.
  // When both fail, a `ms:copy-failed` event is dispatched carrying the text so
  // the host can offer it another way; nothing is silently lost.
  async copyText(text) {
    if (window.isSecureContext && navigator.clipboard) {
      try {
        await navigator.clipboard.writeText(text)
        this.notify("copied", { length: text.length })
        return true
      } catch {
        // Permission denied, or the document is not focused. Fall through.
      }
    }

    if (this.copyWithSelection(text)) {
      this.notify("copied", { length: text.length, fallback: true })
      return true
    }

    this.notify("copy-failed", { text })
    return false
  }

  copyWithSelection(text) {
    const carrier = document.createElement("textarea")
    carrier.value = text
    carrier.setAttribute("readonly", "")
    carrier.setAttribute("aria-hidden", "true")
    carrier.style.position = "fixed"
    carrier.style.top = "0"
    carrier.style.left = "-9999px"
    document.body.appendChild(carrier)

    const previous = document.activeElement
    let copied = false
    try {
      carrier.select()
      carrier.setSelectionRange(0, carrier.value.length)
      copied = document.execCommand("copy")
    } catch {
      copied = false
    } finally {
      carrier.remove()
      if (previous instanceof HTMLElement) previous.focus()
    }
    return copied
  }

  // ---------------------------------------------------------------- downloads

  downloadText(text, filename, mime = "text/plain") {
    const blob = new Blob([text], { type: `${mime};charset=utf-8` })
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    link.href = url
    link.download = this.safeFilename(filename)
    link.rel = "noopener"
    document.body.appendChild(link)
    link.click()
    link.remove()
    // Revoking synchronously races the download in Safari.
    setTimeout(() => URL.revokeObjectURL(url), 1000)
    this.notify("downloaded", { filename: link.download })
  }

  // A filename is built from a DOM-derived language string. Path separators,
  // control characters and leading dots are stripped rather than trusted.
  safeFilename(name) {
    const cleaned = String(name)
      .replace(/[\u0000-\u001f\u007f]/g, "")
      .replace(/[\\/:*?"<>|]/g, "-")
      .replace(/^\.+/, "")
      .trim()
    return cleaned.length ? cleaned.slice(0, 120) : "download.txt"
  }

  // ------------------------------------------------------------------- events

  notify(name, detail = {}) {
    this.dispatch(name, { detail, prefix: "ms" })
  }
}
