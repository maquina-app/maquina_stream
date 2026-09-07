# maquina_stream — working conventions

A Rails engine: renders streaming markdown server-side, broadcasts it over Turbo.
Tail repair comes from `maquina_remend`, consumed as a published gem — never vendored,
never a path: dependency.

Read the doc before writing code in its area. The names in these documents are fixed;
do not invent alternatives.

| Doc | Read before |
|---|---|
| `docs/streaming.md` | the Streamable contract, the broadcaster, `stream_for:` |
| `docs/configuration.md` | any option — it lists every one |
| `docs/javascript.md` | the DOM contract and Stimulus identifiers |
| `docs/repair.md` | the repair routes and seams |
| `docs/security.md` | sanitization, payload handling |
| `docs/registries.md` | registering renderers or components |
| `docs/deferred-renderers.md` | client-deferred leaf nodes |

## Non-negotiables

- **Minitest with fixtures.** Never RSpec. Never FactoryBot.
- **No service objects.** Rich models, thin controllers, plain POROs where a model
  doesn't fit — not an `app/services` layer. A solution needing a framework-shaped
  abstraction is the wrong solution.
- **NoBuild.** No package.json, no JS bundler, no npm dependency. JavaScript ships via
  importmap; third-party libraries are pinned and lazily imported.
- **Spanish is the default locale.** English is the secondary translation.

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

One phase per session: Shape → Tasks → Implement → Verify, with the phase's
progress tracked alongside its spec.

Do not start a phase whose predecessors' DoD is unmet. Do not mark a DoD line met without
the verification that backs it — if the verification needs a harness that doesn't exist,
build it or say it's missing. Reporting a phase complete on unverified criteria is the
single worst outcome here.

## Commit style

Conventional commits, scoped: `feat(stream): key blocks by index, not content`.
