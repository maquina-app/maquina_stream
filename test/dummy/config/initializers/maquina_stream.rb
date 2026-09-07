# frozen_string_literal: true

MaquinaStream.configure do |c|
  # Host seams: the engine resolves and authorizes nothing on its own.
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize = ->(record, _request) { record.present? }
end

# Fence registry — one language of each strategy, which is what the Phase 2 DoD
# asks a host to be able to copy.
#
#   :server       highlighted here, at fence close, into the code_block component
#   :client       one JSON payload for one leaf node, emitted only once closed
#   :passthrough  left exactly as it arrived
MaquinaStream.register_fence "ruby", strategy: :server
MaquinaStream.register_fence "sql", strategy: :server
MaquinaStream.register_fence "text", strategy: :passthrough

MaquinaStream.register_fence "mermaid",
  strategy: :client,
  controller: "ms-diagram",
  payload: ->(source, info) { {source: source, info: info} }

# Tag registry — the reference case, not a toy. A model citing its sources emits
#
#   <source id="3" href="https://example.com/a" title="Un artículo"></source>
#
# and the engine renders it through the source_citation component, keeping only
# the attributes registered here. Anything else the model puts on the tag is
# dropped before the sanitizer ever sees it.
#
# The registered attribute names are passed to the partial as locals, so they
# have to match the locals the partial declares - `href`, not `url`.
MaquinaStream.register_tag :source,
  attributes: %w[id href title],
  partial: "maquina_stream/components/source_citation",
  literal_content: false

# A third renderer, added by the host with no engine change. This is the Phase 6
# DoD line: a host can add a renderer using only the documented registry.
#
# `ms-timeline` is not mentioned anywhere in the engine. The registry carries
# the controller name and the payload shape; the controller is the host's.
MaquinaStream.register_fence "timeline",
  strategy: :client,
  controller: "ms-timeline",
  payload: ->(source, info) { {source: source, info: info, format: "timeline"} }

# The math renderer, wired host-side exactly like the diagram one. `ms-math`
# ships with the engine but no fence name does: which fence means "math" is the
# host's decision, and this is the one the harness exercises.
MaquinaStream.register_fence "math",
  strategy: :client,
  controller: "ms-math",
  payload: ->(source, _info) { {source: source, display: true} }
