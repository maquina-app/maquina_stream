# Component scope and the extraction seam

`maquina_stream` renders **one message**. It does not own the conversation. Prompt inputs, model selectors, voice controls and workflow canvases sit above the renderer and belong to the host.

Vercel's AI Elements library has 48 components. Eight pass our criteria: we need it, its state lives in a Rails model, and it decomposes into `data-component` + variant + ERB locals.

## Interim arrangement

Components that will eventually live in `maquina_components` are **vendored inside `maquina_stream` for now**, built to `maquina_components` conventions from day one. This avoids a cross-gem ordering problem before either gem exists.

Extraction must be mechanical, not a matter of discipline. Four rules:

1. **Render through the seam.** Never render a vendored partial directly. `MaquinaStream::Components#component` resolves to `maquina_components` when present and the vendored copy when absent. Extraction deletes the fallback branch; nothing else changes.
2. **Use destination names.** `data-component="code-block"`, never `"ms-code-block"`. Divergent names fork the CSS and turn extraction into a rewrite.
3. **One stylesheet per component**, loaded only when the fallback is active. Otherwise the day `maquina_components` ships the same selector you get duplicate rules.
4. **A test asserts no engine code renders a vendored partial directly.** Only the helper may. This is what keeps the seam intact once code is being written at speed.

Every vendored partial carries a header comment:

```erb
<%# EXTRACTION CANDIDATE → maquina_components. See docs/component-scope.md %>
```

`lib/maquina_stream/vendored_components.rb` lists them. When the list empties, the seam's fallback branch is deleted.

## The eight

### Vendored now, extract later

| Component | Why it passes | Notes |
|---|---|---|
| **Attachment** | Maps directly onto ActiveStorage: `filename`, `content_type`, `byte_size`, variant URLs. No client-held state. | Three variants: grid, inline, list. Media category derived from `content_type` in Ruby, not a JS utility. Remove is `button_to` with `turbo_method: :delete`. |
| **Code Block** | Both the engine and the component library want one; there must be exactly one implementation. | Phase 2's Rouge output renders *into* this partial rather than emitting its own markup. Keeps streamed and documentation code blocks identical. |
| **Suggestion** | Chips above a prompt input. Server-rendered link or `button_to`, no state. | Roughly an hour of work. |
| **Snippet** | Single command with a copy button. | Shares the copy controller with Code Block, so nearly free once that exists. Used in the engine's own README and dummy app. |

### Stays in the engine permanently

| Component | Why |
|---|---|
| **Shimmer** | The skeleton for open blocks and unrendered deferred payloads. Pure CSS, zero JS, server-rendered. Closes the "skeleton" ambiguity in Phases 2 and 6. |
| **Sources / Inline Citation** | The reference implementation of `register_tag :source`. Model emits `<source id="123">Title</source>`; the Nokogiri pass swaps it for a partial. Satisfies Phase 2's registry-example DoD with a real case. |
| **Conversation download** | Not a component — a utility, already Phase 7's export task. Read Vercel's `messagesToMarkdown` for the formatter-hook shape before writing ours. The scroll half is `ms-autoscroll` in Phase 5. |

### Conditional

| Component | Trigger |
|---|---|
| **File Tree** | Passes the Rails test cleanly (renders from a nested hash, no client state) but the need is Fragua-specific: changed files in a spec-to-PR run. Convert when that screen is built. Listed so it is not rediscovered from scratch. |

## What fails, and why

**Prompt Input, Model Selector** — fail on shape, not need. Both are compositions of form primitives `maquina_components` already has. Build them as app-level compositions with `form_with`.

**Task, Plan, Chain of Thought, Reasoning, Agent, Tool, Checkpoint, Context, Queue** — their data model *is* Fragua's domain. A generic version would be strictly worse than writing them against real phase and cost models. Note that Reasoning and Chain of Thought wrap streamed markdown, so they *compose with* `maquina_stream` rather than duplicating it.

**Canvas, Node, Edge, Connection, Controls, Panel, Toolbar** — need a graph layout library; a project in itself.

**Sandbox, JSX Preview, Artifact, Web Preview** — assume a JS execution environment we do not have.

**All six Voice components** — no current need.

**Terminal, Stack Trace, Test Results, Package Info, Environment Variables, Schema Display, Commit, Confirmation, Persona, Open In Chat** — niche. Convert on demand if a screen calls for one.

## Conversion warning

AI Elements is built on the AI SDK's client-side data model: `message.parts`, `FileUIPart`, `SourceDocumentUIPart`. Converting faithfully imports that model into Rails and fights the server-rendered decision directly.

**Take the visual design and DOM structure, not the props API.** Where their component takes `data={file}` shaped by the AI SDK, ours takes ERB locals shaped by an ActiveRecord model. The `maquina-component-converter` skill's `<%# locals: (...) %>` pattern makes this natural, but an agent handed the React source will mirror prop names unless told not to.
