# frozen_string_literal: true

require "rouge"

module MaquinaStream
  class Renderer
    # One fenced code block, and the decision about what to do with it.
    #
    # The strategy comes from the fence registry; the fence's own state — open or
    # closed — decides how much of that strategy actually runs. An open fence is
    # never highlighted and never emits a client payload: highlighting would be
    # thrown away on the next frame, and a payload would hand the client half a
    # diagram to draw.
    #
    # Which strategy a fence gets is the host's, through
    # MaquinaStream.register_fence. This class is what reads that registration
    # and applies it.
    class Fence
      # What an unregistered language gets: Rouge highlighting once it closes.
      DEFAULT_STRATEGY = :server

      # The three strategies, documented on Registries#register_fence. A
      # registration naming anything else falls back to DEFAULT_STRATEGY rather
      # than raising — a typo in an initializer should not take a whole
      # message down.
      STRATEGIES = %i[server client passthrough].freeze

      # The fence's whole info string, `"ruby"` or `"mermaid graph"`.
      attr_reader :info

      # The fence's body, as written.
      attr_reader :source

      # Whether the fence is still unterminated.
      attr_reader :open

      # The Configuration this fence reads.
      attr_reader :config

      # Builds a fence. The render pipeline does this, once per fenced block
      # per frame.
      def initialize(info:, source:, open:, config:)
        @info = info.to_s
        @source = source
        @open = open
        @config = config
      end

      # Whether the fence is still unterminated. An open fence is never
      # highlighted and never emits a payload.
      def open? = @open

      # Whether the fence has closed, and may therefore be highlighted or
      # emit a payload.
      def closed? = !open?

      # The first word of the info string — what the registry is keyed on.
      def language
        info.split(/\s+/).first.to_s
      end

      # This language's registration, or nil when nobody registered it.
      def registration
        MaquinaStream.fences[language]
      end

      # The strategy in force for this fence: one of STRATEGIES, and
      # DEFAULT_STRATEGY for anything unregistered or misregistered.
      def strategy
        candidate = registration&.options&.fetch(:strategy, nil) || DEFAULT_STRATEGY
        STRATEGIES.include?(candidate) ? candidate : DEFAULT_STRATEGY
      end

      # The Stimulus identifier a `:client` fence hands its payload to, from
      # the registration's `controller:`. Nil for any other strategy.
      def controller
        registration&.options&.fetch(:controller, nil)
      end

      # The Hash a `:client` fence hands its controller, or nil.
      #
      # Built by the registration's `payload:` callable, and `{source:, info:}`
      # when it has none. It is serialized to JSON into a data attribute, so
      # the callable must return something JSON-representable.
      #
      # The payload exists only once the fence has closed. Until then there is
      # nothing here for the client to render, by design.
      def payload
        return nil unless strategy == :client && closed?

        builder = registration&.options&.fetch(:payload, nil)
        return {source: source, info: info} unless builder.respond_to?(:call)

        builder.call(source, info)
      end

      # Highlighted HTML, or nil when this fence should not be highlighted at
      # all: an open fence, a passthrough language, or a language Rouge does not
      # know.
      def highlighted
        return nil unless strategy == :server && closed?

        lexer = Rouge::Lexer.find(language)
        return nil unless lexer

        formatter.format(lexer.lex(source))
      end

      private
        def formatter
          @formatter ||= Rouge::Formatters::HTML.new
        end
    end
  end
end
