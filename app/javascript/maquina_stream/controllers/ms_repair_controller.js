import ApplicationController from "maquina_stream/controllers/application_controller"

// `ms-repair` — reconcile the message with the server.
//
//   <div id="ms-msg-42"
//        data-controller="ms-stream ms-repair"
//        data-ms-repair-manifest-url-value="/maquina_stream/42/manifest"
//        data-ms-repair-blocks-url-value="/maquina_stream/42/blocks"
//        data-ms-repair-interval-value="4000">
//
// Action Cable gives no delivery guarantee, no ordering guarantee and no gap
// detection. Deltas are an optimization; this is where correctness lives.
//
// Four triggers, per docs/design.md:
//
//   1. final seal, always
//   2. a gap in the sequence
//   3. reconnect, or the tab becoming visible again
//   4. a periodic keyframe
//
// What it fetches is decided by digests, not by guesswork: the manifest is a
// few hundred bytes, the client compares it against its own DOM, and asks only
// for the blocks that differ. Repair therefore costs what has drifted, not what
// the message weighs.
export default class extends ApplicationController {
  static values = {
    manifestUrl: String,
    blocksUrl: String,
    interval: { type: Number, default: 4000 },
    seq: { type: Number, default: 0 },
    rollup: { type: String, default: "" }
  }

  connect() {
    this.onVisibility = () => { if (!document.hidden) this.repair("visible") }
    this.onConnect = () => this.repair("reconnect")
    this.onStreamFrame = (event) => this.observe(event)

    document.addEventListener("visibilitychange", this.onVisibility)
    document.addEventListener("turbo:before-stream-render", this.onStreamFrame)
    window.addEventListener("online", this.onConnect)

    this.start()
  }

  disconnect() {
    this.stop()
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("turbo:before-stream-render", this.onStreamFrame)
    window.removeEventListener("online", this.onConnect)
  }

  start() {
    this.stop()
    if (this.intervalValue > 0) this.timer = setInterval(() => this.repair("keyframe"), this.intervalValue)
  }

  stop() {
    clearInterval(this.timer)
    this.timer = null
  }

  // ------------------------------------------------------------------ triggers

  // Every frame carries its sequence. A number that is not exactly one more
  // than the last means a frame never arrived, and the DOM is now a guess.
  observe(event) {
    const stream = event.target
    const seq = Number(stream.dataset.msSeq)
    if (!Number.isFinite(seq) || seq === 0) return

    const expected = this.seqValue + 1
    this.seqValue = seq

    if (this.seqValue > expected) this.repair("gap")
    if (stream.dataset.msFrame === "final") this.repair("seal")
  }

  // ------------------------------------------------------------------ repair

  async repair(reason) {
    if (this.running) return
    this.running = true

    try {
      const manifest = await this.fetchManifest()
      if (!manifest) return

      // History behind the window disagrees, so the window is not enough to
      // reconcile from. Rare, and the same work a cold page load does.
      if (manifest.cutoff > 0 && manifest.rollup !== this.rollupValue) {
        const full = await this.fetchManifest({ full: true })
        if (full) await this.reconcile(full, reason)
        return
      }

      await this.reconcile(manifest, reason)
    } catch (error) {
      // A failed repair is not fatal: the next trigger tries again, and the
      // final seal always fires.
      this.notify("repair-failed", { reason, error: String(error) })
    } finally {
      this.running = false
    }
  }

  async reconcile(manifest, reason) {
    const stale = manifest.blocks.filter(([id, digest]) => this.digestOf(id) !== digest).map(([id]) => id)
    this.rollupValue = manifest.rollup || ""
    if (stale.length === 0) return

    const html = await this.fetchBlocks(stale)
    if (!html) return

    // Silent by construction: suppress before the morph, resume after it. A
    // repair that re-animates text already on screen is the strobe Phase 0
    // exists to prevent.
    this.suppressReveal()
    try {
      window.Turbo.renderStreamMessage(html)
      await this.nextFrame()
    } finally {
      this.resumeReveal()
    }

    this.notify("repaired", { reason, blocks: stale.length })
  }

  // The digest the client can compute for what it currently holds. The server
  // digests the block's rendered HTML, so the client digests the same bytes.
  digestOf(id) {
    const node = document.getElementById(id)
    return node ? node.dataset.msBlockDigest : null
  }

  async fetchManifest(params = {}) {
    const url = new URL(this.manifestUrlValue, window.location.origin)
    if (params.full) url.searchParams.set("full", "1")

    const response = await fetch(url, { headers: { Accept: "application/json" } })
    return response.ok ? response.json() : null
  }

  async fetchBlocks(ids) {
    const url = new URL(this.blocksUrlValue, window.location.origin)
    ids.forEach((id) => url.searchParams.append("ids[]", id))

    const response = await fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" } })
    return response.ok ? response.text() : null
  }

  // The suppression seam. Dispatched as events rather than called directly, so
  // it works for whichever reveal strategy Phase 0 settles on: a controller
  // that needs to stay quiet listens, and one that is structurally immune
  // (strategy C) simply does not.
  suppressReveal() {
    this.element.dispatchEvent(new CustomEvent("ms:suppress", { bubbles: false }))
  }

  resumeReveal() {
    this.element.dispatchEvent(new CustomEvent("ms:resume", { bubbles: false }))
  }

  nextFrame() {
    return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
  }
}
