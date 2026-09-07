# Phase 5 — Interaction layer

**Depends on:** Phase 2. **Blocks:** nothing. Runs while Phase 0's gate is open.

## What this phase is

Everything the reader does with a message once it is on screen: copy, download,
follow a link safely, and scroll without being fought. Four Stimulus controllers,
two more vendored components, two complete locales, and a configuration switch
for every single control.

## Rules that shape it

- **NoBuild.** Importmap only. A third-party library is pinned and lazily
  imported, never bundled.
- **Every value a controller reads is untrusted.** The sanitizer runs over
  already-merged HTML and cannot tell an attribute the post-pass wrote from one
  an injected fragment asked for (`docs/sanitizer.md`). A controller never
  assigns a DOM-derived string as raw HTML.
- **Copy reads the raw-source carrier, never the highlighted markup.** The
  carrier is `<pre hidden data-ms-code-source>` — ordinary escaped text, so
  there is nothing to unescape and no script element to trust.
- **Autoscroll must not fight the reader.** Sticking to the bottom is the
  default; the moment the reader scrolls up it releases and stays released until
  they return to the bottom themselves.
- **Controls are inert while streaming.** Copying half a code block is worse
  than not offering to.
- **Spanish is the default locale**, English secondary, both complete. A missing
  translation fails the build rather than falling back silently.

## Verification

- Keyboard-only pass: every control reachable, focus visible, the link dialog
  traps focus and restores it to the trigger.
- Screen reader pass: meaningful accessible names, copy actions announce their
  result.
- Clipboard in Chrome, Firefox and Safari, including the insecure-context
  fallback (`navigator.clipboard` does not exist over plain HTTP).
- Scrolling up mid-stream is not overridden by later frames.
- Controls inert while streaming.

### What an agent cannot verify here

The keyboard pass is automatable and is automated, in a real browser against a
harness page in the dummy app. **The screen reader pass is not.** No agent in
this session can drive VoiceOver, NVDA or JAWS, and asserting the presence of an
`aria-label` is not the same as hearing what gets announced. That DoD line stays
open until a person does it, and the harness page exists so that is a ten-minute
job rather than a project.

The three-browser clipboard check is likewise partly open: the harness can be
driven in Chromium here, and Firefox and Safari need a person or a CI matrix.

## Definition of done (from docs/plan.md)

- [ ] Full keyboard and screen reader pass completed with findings fixed, not
      logged. **Keyboard half automatable; screen reader half needs a human.**
- [ ] Both locales complete, Spanish default.
- [ ] Every control individually disableable via configuration.
