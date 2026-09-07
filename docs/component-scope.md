# Component scope and the extraction seam

`maquina_stream` renders **one message**. It does not own the conversation. Prompt inputs, model selectors, voice controls and workflow canvases sit above the renderer and belong to the host.

Vercel's AI Elements library has 48 components. Eight pass our criteria: we need it, its state lives in a Rails model, and it decomposes into `data-component` + variant + ERB locals.

## Interim arrangement

Components that will eventually live in `maquina_components` are **vendored inside `maquina_stream` for now**, built to `maquina_components` conventions from day one. This avoids a cross-gem ordering problem before either gem exists.

Extraction must be mechanical, not a matter of discipline. Five rules:

1. **Render through the seam.** Never render a vendored partial directly. `MaquinaStream::Components#component` resolves to `maquina_components` when present and the vendored copy when absent. Extraction deletes the fallback branch; nothing else changes.
2. **Use destination names.** `data-component="code-block"`, never `"ms-code-block"`. Divergent names fork the CSS and turn extraction into a rewrite.
3. **One stylesheet per component**, loaded only when the fallback is active. Otherwise the day `maquina_components` ships the same selector you get duplicate rules.
4. **A test asserts no engine code renders a vendored partial directly.** Only the helper may. This is what keeps the seam intact once code is being written at speed.
5. **No engine names inside a vendored partial.** No `data-ms-*`, no `ms-*` Stimulus identifier, no `maquina_stream.*` label, no `MaquinaStream.config`. All of it is supplied at the call site by `MaquinaStream::Components::Contract`, and a test fails when a partial takes any of it back. Extraction moves markup, not a rewrite.

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
`lib/maquina_stream/configuration.rb`, where the shape is documented. The
partials read no configuration themselves — the call site resolves
`config.controls` into a `controls:` local.

Stylesheets are one per component under `app/assets/stylesheets/maquina_stream/components/`, and the host loads what `component_stylesheets` reports.

`test/maquina_stream/components_test.rb` holds the seam's guarantees, including the direct-render check: it greps `{app,lib}/**/*.{rb,erb}` for a component partial path named next to a `render`, allowing only the resolver, the helper and the test itself. A companion test plants a violating template in a temporary tree and asserts the same check reports it, so the guard cannot rot into a tautology.

Two attribute shapes the components render have to survive `MaquinaStream::Sanitizer` or the fallback CSS stops matching:

- `<pre hidden data-ms-code-source>` — the raw-source carrier from the DOM contract in `docs/api-surface.md`. It was a `<script type="text/plain">` until Phase 2; the sanitizer drops every script element and must keep doing so. The partial no longer writes that attribute itself — it arrives as `source_attributes` from the call site (see the extraction review below) — but the sanitizer still has to let it through.
- `data-<component>-part` — the `maquina_components` part convention (`data-code-block-part`, `data-shimmer-part`, …). This one is the component's own, and stays in the partial.

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

## Extraction review (Phase 7, 2026-09-06, revised 2026-09-07)

`docs/plan.md` asks this phase to "confirm each is still a candidate, and that
the seam's fallback branch is the only thing blocking extraction."

**Each of the four is still a candidate. The fallback branch was not the only
thing blocking extraction** — there were three couplings. Two of them are now
gone; the third is not a blocker at all once it is looked at properly.

| Component | Couplings, as found on 2026-09-06 | Now |
|---|---|---|
| `code_block` | `data-ms-code`, `data-ms-code-lang`, `data-ms-code-source`, `data-ms-control`, `ms-code`; `maquina_stream.code.*` | supplied at the call site |
| `snippet` | `data-ms-code-source`, `ms-code`; `maquina_stream.snippet.*` | supplied at the call site |
| `attachment` | `data-ms-attachment-target`, `ms-attachment`, `MaquinaStream.config`; `maquina_stream.attachment.*`, `maquina_stream.number.*` | supplied at the call site |
| `suggestion` | `MaquinaStream.config`; `maquina_stream.suggestion.*` | supplied at the call site |

### 1. The `data-ms-*` attributes are the engine's contract — fixed

`docs/api-surface.md` fixes them and `ms-code` binds to them. A generic
component library shipping `data-ms-code-source` would be carrying
maquina_stream's DOM contract into every app that installs it for a button.

**The fix was at the call site, and it has been made.**
`MaquinaStream::Components::Contract` (`lib/maquina_stream/components/contract.rb`)
is the engine's half of a vendored component. It turns engine inputs into
generic locals:

```ruby
Contract.apply(:code_block, {lang: "ruby", source: raw, controls: {copy: true}})
# => {lang: "ruby", source: raw, controls: {copy: true},
#     data: {ms_code: "", ms_code_lang: "ruby", controller: "ms-code"},
#     source_attributes: {"data-ms-code-source" => ""},
#     copy_attributes: {"data-ms-control" => "", "data-action" => "ms-code#copy"},
#     copy_label: "Copiar", copy_aria_label: "Copiar el código", …}
```

Root-level contract attributes ride in `data:`, which the partials already
merged rather than overwrote. Attributes on a *part* — the raw-source carrier,
a control button, the thumbnail's failure hook — ride in an `*_attributes`
local the partial splats with `tag.attributes`. There are exactly two callers,
both in the engine: `ComponentsHelper#component`, and `Renderer::PostPass`,
which renders the fence partial from outside a request.

Two consequences worth knowing:

* The contract renders as `data-ms-code=""` rather than as a bare
  `data-ms-code`. Same attribute, same `[data-ms-code]` selector; the golden
  files already recorded it that way, because the serializer normalises it.
* A control with no label is not rendered. A generic component owns no strings,
  so "the caller has not named this button" and "the caller does not want this
  button" are the same statement.

### 2. The locale namespace — fixed the same way

All four used to translate under `maquina_stream.*`. They now take their
labels as locals, and the `maquina_stream.*` keys stay where they belong: in
this engine's `config/locales`, read by `Contract`, which does not move. The
attachment's size formatting is the one that took thought — it needs unit
names and a decimal separator, so it takes `size_units:`, `size_format:` and
`decimal_separator:` and keeps the arithmetic, which is not language.

Extraction therefore migrates no keys. `maquina_components` will want defaults
of its own for a host that renders these components directly, but that is the
destination gem's business, not a migration of ours.

### 3. `component_html_options` travels WITH the partials, and never blocked them

This one cannot be passed as a local and should not be. It is not data, it is
behaviour invoked on every render — data-attribute merging, `css_classes`,
symbol defaults — and it is exactly what makes these partials house-style. It
belongs in `maquina_components` **alongside** them.

So it is a coupling to the *destination*, not to this engine: the partials
depend on a conventions helper that will exist there. Until it does, the
vendored copies use the engine's copy in
`app/helpers/maquina_stream/components_helper.rb`. Extraction publishes the
helper in `maquina_components` and deletes ours; nothing about the partials
changes. The engine keeps only `Contract`, which calls no part of it.

One duplication is deliberate: `Contract.merge_data` restates the
data-attribute merge rule (ours wins its own keys, `controller` and `action`
concatenate) because it applies the rule one level earlier, before the partial
sees a single `data:` local — and because the helper leaves and `Contract`
stays. Both are commented as being the same rule.

### What is genuinely mechanical

The resolver. `Components.partial_for` already probes for the real path in the
destination gem, `Components.stylesheets` already drops a fallback stylesheet
the moment the gem serves that component, and a test already fails if any
engine code renders a vendored partial directly. When these move, the engine
stops resolving to its own copies with no code change on this side.

### What is still cosmetic, and deliberately left

The vendored partials' own class names are `ms-`-prefixed — `ms-code-block`,
`ms-snippet`, `ms-attachment--grid`, `ms-suggestion-chip` — and they pair with
the fallback stylesheets under
`app/assets/stylesheets/maquina_stream/components/`. Class names and stylesheet
move together and neither is part of any contract, so this is a rename at
extraction time, not a coupling. It is left alone rather than churned now:
renaming would touch the CSS, the golden files and nothing else of value.

### The guard

`test/maquina_stream/components_test.rb` fails if a vendored partial names
`data-ms-`, an `ms-*` Stimulus identifier, `maquina_stream` (locale keys and
`maquina_stream_config` both), or calls `t(`. ERB comments are stripped first:
a partial may explain the contract it is handed without carrying it.

### Still engine-owned, correctly

`shimmer` and `source_citation` are not candidates and should not become ones.
`shimmer` is the single skeleton the whole engine renders; `source_citation` is
the reference implementation of `register_tag :source`. Both are about this
engine's behaviour rather than about a design system, so both keep their
`data-ms-*` attributes and their `maquina_stream.*` labels, and `Contract`
returns them nothing.
