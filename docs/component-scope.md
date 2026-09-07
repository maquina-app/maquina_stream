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

`MaquinaStream::VENDORED_COMPONENTS` (in `lib/maquina_stream.rb`) lists them. When the list empties, the seam's fallback branch is deleted.

## What is built (Phase 2)

The resolver lives in `lib/maquina_stream/components.rb`; the view side is `component(...)` in `app/helpers/maquina_stream/components_helper.rb`.

```ruby
MaquinaStream::Components.partial_for(:code_block, config: MaquinaStream.config)
# => "maquina_components/code_block"        when the gem is present AND defines it
# => "maquina_stream/components/code_block" otherwise

MaquinaStream::Components.vendored?(:code_block)   # => true
MaquinaStream::Components.engine_owned?(:shimmer)  # => true
```

Resolution falls back to the vendored partial when the gem is absent, when the gem is present but does not define that component, and when `config.components` is `:plain`. Engine-owned components never resolve to the gem at all. `MaquinaStream::Components.stylesheets` returns the fallback stylesheets that are actually active — a component the gem serves loads none of ours, so the selectors are never defined twice.

| Partial | `data-component` | Status |
|---|---|---|
| `app/views/maquina_stream/components/_attachment.html.erb` | `attachment` | vendored, extract later |
| `app/views/maquina_stream/components/_code_block.html.erb` | `code-block` | vendored, extract later |
| `app/views/maquina_stream/components/_snippet.html.erb` | `snippet` | vendored, extract later |
| `app/views/maquina_stream/components/_suggestion.html.erb` | `suggestion` | vendored, extract later |
| `app/views/maquina_stream/components/_shimmer.html.erb` | `shimmer` | engine-owned, permanent |
| `app/views/maquina_stream/components/_source_citation.html.erb` | `source-citation` | engine-owned, permanent |

All six are built (Phase 5 added `attachment` and `suggestion`), each with its
own stylesheet. `attachment` renders three variants — `grid`, `inline`, `list` —
from ActiveStorage's own attribute names, and `suggestion` is a server-rendered
chip row with no client state and no Stimulus controller. Every control either
one of them offers is switchable through `config.controls`; see
`lib/maquina_stream/configuration.rb`, where the shape is documented.

Stylesheets are one per component under `app/assets/stylesheets/maquina_stream/components/`, and the host loads what `component_stylesheets` reports.

`test/maquina_stream/components_test.rb` holds the seam's guarantees, including the direct-render check: it greps `{app,lib}/**/*.{rb,erb}` for a component partial path named next to a `render`, allowing only the resolver, the helper and the test itself. A companion test plants a violating template in a temporary tree and asserts the same check reports it, so the guard cannot rot into a tautology.

Two attribute shapes the vendored partials emit have to survive `MaquinaStream::Sanitizer` or the fallback CSS stops matching:

- `<script type="text/plain" data-ms-code-source>` — the raw-source carrier from the DOM contract in `docs/api-surface.md`. A `<script>` element is a raw-text element, so the source is not HTML-escaped inside it (entities would not decode); the only sequence that can terminate it, `</script`, is escaped to `<\/script` and `ms-code` reverses that on read.
- `data-<component>-part` — the `maquina_components` part convention (`data-code-block-part`, `data-shimmer-part`, …).

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
| **Shimmer** | The skeleton for open blocks and unrendered deferred payloads. Pure CSS, zero JS, server-rendered. Closes the "skeleton" ambiguity in Phases 2 and 6. Built; a test asserts no other engine template carries placeholder markup. |
| **Sources / Inline Citation** | The reference implementation of `register_tag :source`. Model emits `<source id="123">Title</source>`; the Nokogiri pass swaps it for a partial. Satisfies Phase 2's registry-example DoD with a real case. Built as `source_citation`: it renders a link when the host resolved one, plain text when it did not, and escapes a model-supplied title. |
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

---

## Extraction review (Phase 7, 2026-09-06)

`docs/plan.md` asks this phase to "confirm each is still a candidate, and that
the seam's fallback branch is the only thing blocking extraction."

**Each of the four is still a candidate. The fallback branch is not the only
thing blocking extraction** — there are three couplings, and two of them are
decisions rather than chores.

| Component | Couplings to the engine |
|---|---|
| `code_block` | `data-ms-code`, `data-ms-code-lang`, `data-ms-code-source`; `maquina_stream.code.*` locale keys |
| `snippet` | `data-ms-code-source`; `maquina_stream.snippet.*` |
| `attachment` | `data-ms-attachment-target`; `maquina_stream.attachment.*`, `maquina_stream.number.*` |
| `suggestion` | `maquina_stream.suggestion.*` |

### 1. The `data-ms-*` attributes are the engine's contract, not the component's

`docs/api-surface.md` fixes them, and `ms-code` binds to them. A generic
component library shipping `data-ms-code-source` would be carrying
maquina_stream's DOM contract into every app that installs it for a button.

**The fix is at the call site, not in the partial.** Every vendored partial
already takes `**html_options` and merges data attributes rather than
overwriting them, so the engine can supply its own contract when it renders:

```erb
<%= component(:code_block, lang: "ruby", source: raw,
              data: { ms_code: "", ms_code_lang: "ruby" }) %>
```

That makes the partial generic and leaves the contract where it belongs. It is
a small change and it has not been made yet.

### 2. The locale namespace moves with the component

All four translate under `maquina_stream.*`. Extracted, they would need
`maquina_components.*` (or the host's namespace) and their keys carried across.
Mechanical, but it is a migration rather than a copy.

### 3. `component_html_options` has to travel too

The conventions helper — data-attribute merging, `css_classes`, symbol defaults
— is what makes these partials house-style. It belongs in `maquina_components`
alongside them, not in the engine.

### What is genuinely mechanical

The resolver. `Components.partial_for` already probes for the real path in the
destination gem, `Components.stylesheets` already drops a fallback stylesheet
the moment the gem serves that component, and a test already fails if any engine
code renders a vendored partial directly. When these move, the engine stops
resolving to its own copies with no code change on this side.

### Still engine-owned, correctly

`shimmer` and `source_citation` are not candidates and should not become ones.
`shimmer` is the single skeleton the whole engine renders; `source_citation` is
the reference implementation of `register_tag :source`. Both are about this
engine's behaviour rather than about a design system.
