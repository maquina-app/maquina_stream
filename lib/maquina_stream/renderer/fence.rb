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
    class Fence
      DEFAULT_STRATEGY = :server
      STRATEGIES = %i[server client passthrough].freeze

      attr_reader :info, :source, :open, :config

      def initialize(info:, source:, open:, config:)
        @info = info.to_s
        @source = source
        @open = open
        @config = config
      end

      def open? = @open
      def closed? = !open?

      def language
        info.split(/\s+/).first.to_s
      end

      def registration
        MaquinaStream.fences[language]
      end

      def strategy
        candidate = registration&.options&.fetch(:strategy, nil) || DEFAULT_STRATEGY
        STRATEGIES.include?(candidate) ? candidate : DEFAULT_STRATEGY
      end

      def controller
        registration&.options&.fetch(:controller, nil)
      end

      # The payload exists only once the fence has closed. Until then there is
      # nothing here for the client to render, by design.
      def payload
        return nil unless strategy == :client && closed?

        builder = registration&.options&.fetch(:payload, nil)
        return { source: source, info: info } unless builder.respond_to?(:call)

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
