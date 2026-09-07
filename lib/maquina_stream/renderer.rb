# frozen_string_literal: true

module MaquinaStream
  # Placeholder. Phase 2 (render pipeline) implements this.
  # Contract, from docs/api-surface.md:
  #   .call(markdown, mode:, config:) => SafeBuffer, mode: :streaming | :static
  # Pure function: must run outside a Rails request with no stubbing.
  class Renderer
  end
end
