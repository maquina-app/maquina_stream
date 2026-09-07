# frozen_string_literal: true

module MaquinaStream
  # One registered element override: the element name, and the options it was
  # registered with. See Registries#register_element.
  Element = Struct.new(:name, :options, keyword_init: false)

  # One registered custom tag: the tag name, and the options it was registered
  # with. See Registries#register_tag.
  Tag = Struct.new(:name, :options, keyword_init: false)

  # One registered fence: the info string it matches, and the options it was
  # registered with. See Registries#register_fence.
  Fence = Struct.new(:info, :options, keyword_init: false)

  # The three registries, extended into MaquinaStream itself — so every method
  # here is called as `MaquinaStream.register_element`, not on a registry
  # object. Registrations are global and are read on every render; make them
  # once, from an initializer.
  #
  # See docs/registries.md for the long form.
  module Registries
    # Registered element overrides, keyed by element name. Read by the render
    # pipeline; a host rarely reads it directly.
    def elements = @elements ||= {}

    # Registered custom tags, keyed by tag name.
    def tags = @tags ||= {}

    # Registered fences, keyed by info string.
    def fences = @fences ||= {}

    # Renders one markdown element through a partial of the host's instead of
    # the engine's default markup.
    #
    # ```ruby
    # MaquinaStream.register_element :h2, partial: "my/headings/h2"
    # ```
    #
    # `name` is the HTML element the renderer produced (`:h2`, `:blockquote`,
    # `:table`). The partial receives the element's content and renders in
    # place of it. Registering the same name twice replaces the first
    # registration; the last one in wins.
    #
    # The output still goes through Sanitizer, which runs unconditionally and
    # last. A partial cannot introduce an element or attribute the allowlist
    # does not name.
    def register_element(name, **options)
      elements[name.to_sym] = Element.new(name.to_sym, options)
    end

    # Admits one HTML-ish tag that markdown does not define, and renders it
    # through a partial.
    #
    # ```ruby
    # MaquinaStream.register_tag :source,
    #   attributes: %w[id],
    #   partial: "my/tags/source",
    #   literal_content: false
    # ```
    #
    # | Option | Meaning |
    # |---|---|
    # | `attributes:` | The attribute names the tag may carry. Anything else on it is dropped — the tag is model output, and model output is prompt-injectable. |
    # | `partial:` | The partial that renders it. |
    # | `literal_content:` | `true` keeps the tag's body as text; `false` renders it as markdown. |
    #
    # A tag nobody registered is not markup: it is text, and it is escaped.
    def register_tag(name, **options)
      tags[name.to_sym] = Tag.new(name.to_sym, options)
    end

    # Decides what happens to a fenced code block with this info string.
    #
    # ```ruby
    # MaquinaStream.register_fence "ruby",    strategy: :server
    # MaquinaStream.register_fence "unknown", strategy: :passthrough
    # MaquinaStream.register_fence "mermaid",
    #   strategy: :client,
    #   controller: "ms-diagram",
    #   payload: ->(source, info) { { source: source, info: info } }
    # ```
    #
    # ## The three strategies
    #
    # | Strategy | What it does | When to use it |
    # |---|---|---|
    # | `:server` | Rouge highlights the source once the fence closes, into classes — never inline colour, so a theme switch needs no re-render. The default for every unregistered language. | Anything Rouge has a lexer for. |
    # | `:client` | Nothing is rendered server-side. The block carries a `payload:` as a data attribute and a Stimulus `controller:` draws it in the browser. | Diagrams, math — anything whose renderer is a JavaScript library the server has no business running. |
    # | `:passthrough` | The source is emitted as escaped text and nothing else happens to it. | A language Rouge would mangle, or one whose highlighting is not worth the CPU. |
    #
    # **An open fence is never highlighted and never emits a payload.**
    # Highlighting would be thrown away on the next frame, and a payload would
    # hand the client half a diagram to draw. A `:client` fence renders a
    # skeleton until it closes.
    #
    # `payload:` is a callable receiving `(source, info)` and returning a Hash;
    # it defaults to `{source:, info:}`. It is serialized as JSON into a data
    # attribute, so it must be JSON-representable. **The client sanitizes what
    # its renderer produces** even though the server already sanitized the
    # document — the payload came from the model.
    #
    # See Renderer::Fence and docs/deferred-renderers.md.
    def register_fence(info, **options)
      fences[info.to_s] = Fence.new(info.to_s, options)
    end

    # Empties all three registries. For tests; a host that calls this loses
    # every registration made in its initializer.
    def reset_registries!
      @elements = {}
      @tags = {}
      @fences = {}
    end
  end
end
