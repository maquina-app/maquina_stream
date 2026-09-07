# maquina_stream — working conventions

A Rails engine. It renders streaming markdown server-side and broadcasts it over Turbo.
Tail repair comes from the `maquina_remend` gem, consumed as a published dependency.

Read `docs/` before writing any code — `streaming.md` for the Streamable contract and the
broadcaster, `configuration.md` for every option, `javascript.md` for the DOM contract and
the Stimulus identifiers, `repair.md` for the routes and seams. The names in those
documents are fixed; do not invent alternatives.

## Stack

Rails 8 · Ruby 3.3+ · Hotwire (Turbo 8, morph available) · Tailwind CSS 4 · Importmaps,
**no Node build step** · Solid Queue / Cache / Cable · Minitest with fixtures.

## Non-negotiables

- **Minitest with fixtures.** Never RSpec. Never FactoryBot.
- **No service objects.** Rich models, thin controllers. Plain POROs where a model doesn't
  fit — not an `app/services` layer.
- **NoBuild.** No package.json, no bundler, no npm dependency. JavaScript ships via
  importmap; third-party libraries are pinned and lazily imported.
- **Spanish is the default locale.** English is the secondary translation.
- **Vanilla Rails.** Convention over configuration. If a solution needs a framework-shaped
  abstraction to work, it is the wrong solution.

## This project specifically

- The renderer is a **pure function**. It must run outside a Rails request with no stubbing.
  If it starts needing request context, that's a design error, not a plumbing problem.
- **Only rendered HTML reaches the browser.** The client never parses markdown.
  Client-deferred renderers receive one JSON payload for one leaf node — that is not an
  exception to this rule.
- **Block ids are index-derived, never content-derived.** Idiomorph keys on `id`.
- **Deltas are an optimization; correctness lives in the repair path.** A correctness bug
  fixed inside the delta path is fixed in the wrong place.
- **Never assign model output as raw HTML.** Payloads are prompt-injectable. Renderer output
  gets sanitized client-side even though the server already sanitized the document.
- `maquina_components` is an **optional** dependency. Plain Tailwind fallbacks when absent.
- **Components render through the seam, never directly.** Some components are vendored inside
  the engine for now and will move to `maquina_components` later. Build them to
  `maquina_components` conventions, use destination `data-component` names (`code-block`,
  never `ms-code-block`), and always render via the resolver.
  `MaquinaStream::VENDORED_COMPONENTS` lists the extraction candidates.
- **Do not port React prop APIs.** AI Elements components assume the AI SDK client data model
  (`message.parts`, `FileUIPart`). Take the visual design and DOM structure; the locals are
  shaped by our ActiveRecord models.

## Commands

`mise exec -- bundle exec rake` runs the default task (Minitest + standard).
The host app for tests is `test/dummy`.

## Workflow

One phase per session. Each has an SDD spec folder under
`sdd/specs/YYYY-MM-DD-p<n>-<slug>/` with `progress.yml`. Shape → Tasks →
Implement → Verify.

Do not start a phase whose predecessors' DoD is unmet. Do not mark a DoD line met without
the verification that backs it — if a verification needs a harness that doesn't exist yet,
build the harness or say it is missing. Reporting a phase complete on unverified criteria
is the single worst outcome here.

## Commit style

Conventional commits, scoped: `feat(stream): key blocks by index, not content`.
