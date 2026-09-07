import ApplicationController from "./application_controller"

// `ms-autoscroll` — keep the bottom of a growing message in view while it
// streams, and get out of the way the instant the user scrolls up.
//
//   <div data-controller="ms-autoscroll"
//        data-action="scroll->ms-autoscroll#track wheel->ms-autoscroll#release
//                     touchmove->ms-autoscroll#release"
//        style="overflow-y: auto">
//     <div id="ms-msg-42">…</div>
//   </div>
//
// Or against the window, for a page that scrolls as a whole:
//
//   <div data-controller="ms-autoscroll"
//        data-ms-autoscroll-scroller-value="window"
//        data-action="scroll@window->ms-autoscroll#track
//                     wheel@window->ms-autoscroll#release
//                     touchmove@window->ms-autoscroll#release">
//
// The rule the whole controller exists to keep: **it never scrolls unless it
// is pinned, and only the user can pin it.** A programmatic scroll always
// lands at the bottom, so it re-satisfies the pin condition and never fights
// a user who is reading further up.
export default class extends ApplicationController {
  static values = {
    // "self" (the controller element scrolls) or "window".
    scroller: { type: String, default: "self" },
    // How close to the bottom still counts as "at the bottom", in pixels. A
    // couple of device pixels of rounding is normal, and a sub-pixel layout
    // would otherwise unpin on its own.
    threshold: { type: Number, default: 32 },
    // Serialized so it survives a Turbo morph and can be read from a test.
    pinned: { type: Boolean, default: true }
  }

  connect() {
    // The message grows by morph and by Turbo Stream, neither of which fires a
    // DOM event this controller can hang off. An observer is the only signal.
    this.observer = new MutationObserver(() => this.follow())
    this.observer.observe(this.element, { childList: true, subtree: true, characterData: true })
    this.follow()
  }

  disconnect() {
    this.observer?.disconnect()
    this.observer = null
    cancelAnimationFrame(this.frame)
  }

  // ------------------------------------------------------------------ actions

  // Bound to `scroll`. Pinning is derived from position, never remembered:
  // the user scrolls back to the bottom and is pinned again, by the same rule
  // that unpinned them.
  track() {
    this.pinnedValue = this.atBottom
  }

  // Bound to `wheel` and `touchmove`. Scroll events can lag a gesture by a
  // frame or two on a long document; an upward gesture unpins immediately so
  // the next append does not yank the view back down.
  // An unpin here is never final: the `scroll` event that follows the gesture
  // runs `track`, which pins again if the gesture ended at the bottom.
  release(event) {
    if (event.type === "wheel" && event.deltaY >= 0) return
    this.pinnedValue = false
  }

  // Public, for a "jump to latest" button.
  pin() {
    this.pinnedValue = true
    this.scrollToBottom()
  }

  unpin() {
    this.pinnedValue = false
  }

  pinnedValueChanged(pinned, previous) {
    if (previous === undefined) return
    this.notify("autoscroll", { pinned })
  }

  // ------------------------------------------------------------------ scroller

  get scroller() {
    return this.scrollerValue === "window" ? document.scrollingElement : this.element
  }

  get atBottom() {
    const scroller = this.scroller
    if (!scroller) return true
    const distance = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight
    return distance <= this.thresholdValue
  }

  follow() {
    if (!this.pinnedValue) return
    // Coalesce a burst of appends into one scroll per frame.
    cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => this.scrollToBottom())
  }

  scrollToBottom() {
    const scroller = this.scroller
    if (!scroller) return
    scroller.scrollTop = scroller.scrollHeight
  }
}
