import ApplicationController from "./application_controller"

// The host seam for the allowlist. It is a function, so it cannot live in a
// data attribute — and it must not: an allowlist an injected fragment can
// rewrite is not an allowlist.
//
//   import { linkSafety } from "maquina_stream"
//   linkSafety.allow = (url) => url.hostname.endsWith("example.com")
//
// `url` is a parsed `URL`. Returning true follows the link with no dialog.
export const linkSafety = {
  allow: null
}

// `ms-link-safety` — confirm before following a link out of a rendered message.
//
//   <div data-controller="ms-link-safety"
//        data-action="click->ms-link-safety#intercept">
//     …rendered message, links and all…
//     <dialog data-ms-link-safety-target="dialog">
//       <p data-ms-link-safety-target="url"></p>
//       <label><input type="checkbox" data-ms-link-safety-target="remember"> …</label>
//       <button data-action="ms-link-safety#confirm">Continuar</button>
//       <button data-action="ms-link-safety#cancel">Cancelar</button>
//     </dialog>
//   </div>
//
// Mounted on the message container rather than on each anchor: the anchors are
// model output and the count is unbounded, and one delegated listener survives
// a repair morph that replaces every one of them.
export default class extends ApplicationController {
  static targets = ["dialog", "url", "remember"]

  static values = {
    // Same origin is always followed without a prompt. Anything else is
    // "external" unless the host allowlist or a remembered host says otherwise.
    origin: { type: String, default: "" },
    // Turns the whole guard off — for a host that does its own interstitial.
    bypass: { type: Boolean, default: false },
    // Hosts the user chose to trust, kept for the tab only. Session storage,
    // not local: trust granted mid-conversation should not outlive it.
    rememberKey: { type: String, default: "ms-link-safety.trusted" }
  }

  // A URL the dialog must never offer to follow, whatever the document says.
  // The server sanitizer already drops these; a second check here costs
  // nothing and this controller is the thing that calls `window.open`.
  static allowedProtocols = ["http:", "https:", "mailto:"]

  disconnect() {
    this.closeDialog({ restoreFocus: false })
  }

  // ------------------------------------------------------------------ actions

  // Delegated. Everything that is not an anchor with an href falls straight
  // through to the browser.
  intercept(event) {
    if (event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null
    if (!anchor || !this.element.contains(anchor)) return

    const url = this.parse(anchor.getAttribute("href"))

    // An href we cannot parse, or one on a protocol we refuse, is stopped
    // here. Letting the browser have it is the one thing we must not do.
    if (!url) {
      event.preventDefault()
      this.notify("link-refused", { href: anchor.getAttribute("href") })
      return
    }

    if (this.permitted(url)) return

    event.preventDefault()
    this.ask(url, anchor)
  }

  confirm(event) {
    event?.preventDefault()

    const url = this.pending
    if (this.hasRememberTarget && this.rememberTarget.checked && url) this.trust(url.host)
    this.closeDialog()

    if (!url) return
    this.notify("link-followed", { href: url.href })
    window.open(url.href, "_blank", "noopener,noreferrer")
  }

  cancel(event) {
    event?.preventDefault()
    const url = this.pending
    this.closeDialog()
    this.notify("link-cancelled", { href: url?.href })
  }

  // ------------------------------------------------------------------- policy

  get origin() {
    return this.originValue || window.location.origin
  }

  parse(href) {
    let url
    try {
      url = new URL(href, this.origin)
    } catch {
      return null
    }
    return this.constructor.allowedProtocols.includes(url.protocol) ? url : null
  }

  permitted(url) {
    if (this.bypassValue) return true
    if (url.protocol !== "http:" && url.protocol !== "https:") return true
    if (url.origin === this.origin) return true
    if (this.trusted.has(url.host)) return true

    // The host callback is asked last so it can only widen, never narrow, and
    // a callback that throws denies rather than admits.
    try {
      return Boolean(linkSafety.allow?.(url))
    } catch {
      return false
    }
  }

  get trusted() {
    try {
      return new Set(JSON.parse(window.sessionStorage.getItem(this.rememberKeyValue) || "[]"))
    } catch {
      return new Set()
    }
  }

  trust(host) {
    try {
      const hosts = this.trusted
      hosts.add(host)
      window.sessionStorage.setItem(this.rememberKeyValue, JSON.stringify([...hosts]))
    } catch {
      // Private browsing. Trust simply does not persist.
    }
  }

  // ------------------------------------------------------------------- dialog

  ask(url, anchor) {
    this.pending = url
    this.trigger = anchor

    if (!this.hasDialogTarget) {
      // No dialog in the markup. `window.confirm` traps focus and restores it
      // by itself, so the contract still holds.
      if (window.confirm(url.href)) this.confirm()
      else this.cancel()
      return
    }

    // The href is attacker-influenced text. It is written as text, never as
    // markup, and never into an href on the dialog itself.
    if (this.hasUrlTarget) this.urlTarget.textContent = url.href
    if (this.hasRememberTarget) this.rememberTarget.checked = false

    // `showModal` is the focus trap: the browser makes the rest of the
    // document inert and keeps Tab inside the dialog. Re-implementing that in
    // JavaScript is how focus traps get holes.
    this.dialogTarget.showModal()
    this.boundDialogCancel ||= (event) => {
      // Esc. Route it through `cancel` so one path closes the dialog.
      event.preventDefault()
      this.cancel()
    }
    this.dialogTarget.addEventListener("cancel", this.boundDialogCancel)
    this.notify("link-prompted", { href: url.href })
  }

  closeDialog({ restoreFocus = true } = {}) {
    if (this.hasDialogTarget && this.dialogTarget.open) {
      if (this.boundDialogCancel) {
        this.dialogTarget.removeEventListener("cancel", this.boundDialogCancel)
      }
      this.dialogTarget.close()
    }

    // Focus goes back where it came from, always — the anchor the user
    // clicked, so a keyboard user is not dumped at the top of the document.
    if (restoreFocus && this.trigger?.isConnected) this.trigger.focus()

    this.pending = null
    this.trigger = null
  }
}
