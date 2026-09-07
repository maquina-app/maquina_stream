import ApplicationController from "maquina_stream/controllers/application_controller"

// `ms-reveal` — the streaming reveal, mounted on the message element.
//
//   <div id="ms-msg-42" data-controller="ms-stream ms-repair ms-reveal" data-ms-streaming>
//     <div id="ms-42-b0" data-ms-block …>…</div>
//   </div>
//
// What it does: when a block's text grows, the newly arrived tail is wrapped in
// one `<span data-ms-revealing>`, that span is animated in, and on
// `animationend` the span is unwrapped again. One live extra node per block —
// not one per word — and nothing left in the DOM once the animation ends.
//
// ## Why not the CSS mask
//
// Phase 0's strategy C masked the whole block with a horizontal gradient whose
// edge was placed at `revealed / total` **characters**. A character fraction and
// a horizontal position are the same number only while a block occupies one
// line. On a block wrapped over three lines each line ends at ~94% of the
// block's width, so a mask edge at 75% hid the last fifth of *every* line —
// including lines the reader finished seconds ago — and swept them back in on
// the next frame. That is the flash the review saw on the first few lines of a
// block, fading out as the fraction approached 100%. The geometry is wrong, not
// the easing: no gradient stop fixes a mapping from characters to pixels that
// does not exist.
//
// Wrapping the tail is reading-order correct *by construction*. There is no
// character-to-pixel mapping anywhere, because the thing that animates is the
// new text itself.
//
// ## Why the span is temporary
//
// docs/api-surface.md, "Changed in Phase 7": a block's digest covers what the
// block says, so any chrome the reveal leaves behind is drift the manifest diff
// cannot see and repair cannot correct — two tabs that lost different frames
// end up visibly different with agreeing digests. The span therefore exists
// only for the length of one animation, is removed before a repair morph
// (`ms:suppress`), and is removed on seal, on disconnect and before Turbo
// caches the page.
//
// Nothing here assigns a DOM-derived string as HTML. Per docs/sanitizer.md
// every value a controller reads from the DOM is untrusted; this one moves
// existing text nodes and never re-parses them.
export default class extends ApplicationController {
  static values = {
    // Milliseconds. The stylesheet reads `var(--ms-reveal-duration, 320ms)`;
    // setting this writes the property rather than pinning the duration twice.
    duration: { type: Number, default: 320 },
    // A host that wants the markup but not the animation says so once.
    disabled: Boolean
  }

  // Both fixed by the DOM contract (docs/api-surface.md), like `data-ms-block`
  // itself: the stylesheet and the controller have to agree, and an attribute a
  // host could rename is an attribute the shipped CSS would miss.
  static blockSelector = "[data-ms-block]"
  static markerAttribute = "data-ms-revealing"

  connect() {
    // Transient, and deliberately not a Value. Suppression spans exactly one
    // repair morph; writing it into the DOM would put client state on the
    // element the morph is about to rewrite.
    this.suppressed = false

    // Block id → characters already revealed. Keyed by id rather than by node,
    // because a repair morph may replace the element while keeping its
    // identity (ids are index-derived and stable).
    this.revealed = new Map()

    // Spans currently animating, each with the timer that force-unwraps it if
    // `animationend` never arrives (a hidden or display:none block never fires
    // one, and an orphaned span would then outlive its animation).
    this.pending = new Map()

    if (this.hasDurationValue) {
      this.element.style.setProperty("--ms-reveal-duration", `${this.durationValue}ms`)
    }

    // `ms-repair` dispatches these on the message element, without bubbling.
    // They are wired here rather than through `data-action` because the markup
    // a host renders (docs/api-surface.md) carries `data-controller` and no
    // actions — a reveal that needed one more attribute would silently never
    // suppress, which is the failure mode docs/interaction.md warns about.
    this.onSuppress = () => this.suppress()
    this.onResume = () => this.resume()
    this.root.addEventListener("ms:suppress", this.onSuppress)
    this.root.addEventListener("ms:resume", this.onResume)

    // A tab that was hidden through half a message must not replay it on
    // return; the baseline moves forward instead.
    this.onVisibility = () => { if (!document.hidden) this.sync() }
    document.addEventListener("visibilitychange", this.onVisibility)

    this.onAnimationEnd = (event) => this.settle(event)
    this.element.addEventListener("animationend", this.onAnimationEnd)

    // Two observers, two jobs. Content growth drives the reveal; the message
    // element's `data-ms-streaming` decides whether there is a reveal at all.
    this.contentObserver = new MutationObserver((records) => this.observe(records))
    this.contentObserver.observe(this.element, { childList: true, subtree: true, characterData: true })

    this.stateObserver = new MutationObserver(() => this.arm())
    this.stateObserver.observe(this.root, { attributes: true, attributeFilter: ["data-ms-streaming"] })

    this.arm()
  }

  disconnect() {
    this.contentObserver?.disconnect()
    this.stateObserver?.disconnect()
    this.root.removeEventListener("ms:suppress", this.onSuppress)
    this.root.removeEventListener("ms:resume", this.onResume)
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.element.removeEventListener("animationend", this.onAnimationEnd)
    this.unwrapAll()
  }

  // Turbo caches the page as the reader left it. `index.js` calls this before
  // the snapshot, so a cached message is never restored mid-reveal.
  teardown() {
    this.unwrapAll()
  }

  // -------------------------------------------------------------- suppression

  // The seam `ms-repair` drives. Both are idempotent, and both are safe on a
  // sealed message — a repair can land on one.
  suppress() {
    this.suppressed = true
    this.unwrapAll()
    this.sync()
  }

  // Resume without re-revealing. The morph that just landed put text on screen
  // the reader has already seen, so the baseline moves to the current length:
  // the next delta reveals its tail, not the whole block.
  resume() {
    this.suppressed = false
    this.sync()
  }

  // ------------------------------------------------------------------- arming

  // A sealed message does not animate. The host owns `data-ms-streaming` and
  // stamps it from `maquina_stream_open?`; the seal removing it takes the
  // reveal down live.
  arm() {
    if (this.active) {
      this.sync()
    } else {
      this.unwrapAll()
      this.sync()
    }
  }

  get active() {
    return this.streaming && !this.disabledValue && !this.reducedMotion
  }

  // Reduced motion is answered here and not only in CSS. With `animation: none`
  // no `animationend` ever fires, so a span wrapped anyway would never be
  // unwrapped — the honest reading of the preference is to not wrap at all.
  get reducedMotion() {
    return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false
  }

  // ---------------------------------------------------------------- revealing

  observe(records) {
    // Wrapping and unwrapping are themselves mutations. They never change a
    // block's text length, so they cannot start a reveal, but they are dropped
    // here rather than walked.
    if (this.mutating) return

    if (!this.active || this.suppressed || document.hidden) {
      this.sync()
      return
    }

    const touched = new Set()
    records.forEach((record) => {
      const block = this.blockFor(record.target)
      if (block) touched.add(block)
      record.addedNodes?.forEach((node) => {
        const added = this.blockFor(node)
        if (added) touched.add(added)
      })
    })

    touched.forEach((block) => this.reveal(block))
  }

  reveal(block) {
    const id = this.identify(block)
    const length = block.textContent.length
    const seen = this.revealed.get(id) ?? 0

    this.revealed.set(id, length)
    if (length <= seen) return

    this.surgery(() => this.wrapTail(block, seen).forEach((span) => this.animate(span)))
  }

  // Walk the block's text in document order and wrap everything past `offset`.
  //
  // Text arriving at the end of one text node — the streaming case — yields
  // exactly one span. A frame that also appends new elements (a new list item,
  // a new paragraph inside the block) yields one span per newly written text
  // node, which is bounded by what arrived rather than by what the block holds.
  // A single span cannot span element boundaries without moving text out of the
  // structure it belongs to, and restructuring a block to animate it is exactly
  // the drift this controller exists to avoid.
  wrapTail(block, offset) {
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT)
    const tails = []
    let consumed = 0
    let node

    while ((node = walker.nextNode())) {
      const start = consumed
      consumed += node.nodeValue.length
      if (consumed <= offset) continue
      if (node.parentElement?.hasAttribute(this.constructor.markerAttribute)) continue

      tails.push([node, Math.max(0, offset - start)])
    }

    return tails.map(([text, at]) => this.wrap(at > 0 ? text.splitText(at) : text)).filter(Boolean)
  }

  wrap(text) {
    if (!text.nodeValue.length || !text.parentNode) return null

    const span = document.createElement("span")
    span.setAttribute(this.constructor.markerAttribute, "")
    text.parentNode.insertBefore(span, text)
    span.appendChild(text)
    return span
  }

  animate(span) {
    // The fallback timer, not the animation, is what guarantees the span goes
    // away. `animationend` unwraps first in every normal case.
    const timer = setTimeout(() => this.unwrap(span), this.durationValue + 400)
    this.pending.set(span, timer)
  }

  settle(event) {
    const span = event.target
    if (span instanceof Element && span.hasAttribute(this.constructor.markerAttribute)) this.unwrap(span)
  }

  // Replace the span with the text it holds and normalize, so the block is
  // plain text again and consecutive text nodes do not accumulate over a long
  // message.
  unwrap(span) {
    clearTimeout(this.pending.get(span))
    this.pending.delete(span)

    const parent = span.parentNode
    if (!parent) return

    this.surgery(() => {
      while (span.firstChild) parent.insertBefore(span.firstChild, span)
      span.remove()
      parent.normalize()
    })
  }

  unwrapAll() {
    Array.from(this.element.querySelectorAll(`[${this.constructor.markerAttribute}]`))
      .forEach((span) => this.unwrap(span))
  }

  // Our own DOM writes, fenced off from the observer that watches for the
  // server's.
  surgery(work) {
    const previous = this.mutating
    this.mutating = true
    try {
      work()
    } finally {
      this.contentObserver?.takeRecords()
      this.mutating = previous
    }
  }

  // Re-baseline every block to what is currently on screen. Anything already
  // rendered counts as seen, which is what keeps a reload, a background tab and
  // a repair from replaying text the reader has read.
  sync() {
    this.blocks.forEach((block) => this.revealed.set(this.identify(block), block.textContent.length))
  }

  // --------------------------------------------------------------------- DOM

  // The element the host stamps `data-ms-streaming` on, and the element
  // `ms-repair` dispatches suppression on. Normally `this.element` itself; the
  // lookup only matters for a host that nests the controller.
  get root() {
    return this.messageElement || this.element
  }

  get blocks() {
    return Array.from(this.element.querySelectorAll(this.constructor.blockSelector))
  }

  blockFor(node) {
    const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
    const block = element?.closest(this.constructor.blockSelector)
    return block && this.element.contains(block) ? block : null
  }

  // Block ids are index-derived and stable across a morph (docs/api-surface.md).
  // A block without one is still revealed; it just cannot be tracked across a
  // repair, so it re-baselines instead of re-revealing.
  identify(block) {
    return block.id || `@${block.dataset.msBlockIndex ?? this.blocks.indexOf(block)}`
  }
}
