# frozen_string_literal: true

module MaquinaStream
  # Every key documented in docs/api-surface.md, with its documented default.
  #
  # Three keys are seams the engine cannot supply itself and that
  # docs/api-surface.md names in prose but not in the configuration block:
  # +find_stream+, +authorize+ and +transport+. See docs/engine-contract.md.
  class Configuration
    attr_accessor :frame_budget_ms, :keyframe_interval_ms, :seal_lag,
                  :locale, :components, :themes,
                  :default_origin, :allowed_protocols,
                  :allowed_link_prefixes, :allowed_image_prefixes,
                  :allow_data_images, :controls,
                  :find_stream, :authorize, :transport

    def initialize
      @frame_budget_ms      = 60
      @keyframe_interval_ms = 4_000
      @seal_lag             = 2
      @locale               = :es
      @components           = :maquina
      @themes               = { light: "github", dark: "github_dark" }

      @default_origin         = nil
      @allowed_protocols      = %w[http https mailto]
      @allowed_link_prefixes  = ["*"]
      @allowed_image_prefixes = ["*"]
      @allow_data_images      = true

      @controls = {
        code:  { copy: true, download: true },
        table: { copy: true, download: true, fullscreen: true },
        image: { download: true },
        link_safety: true
      }

      # Host seams. The engine never guesses a record and never assumes it may
      # serve one: with no host callable configured, every request is refused.
      @find_stream = nil
      @authorize   = nil
      @transport   = :turbo_streams
    end

    # Resolves the record a request is about. Refuses when the host has not
    # configured a finder.
    def find_stream!(sid)
      raise ConfigurationError, <<~MESSAGE unless find_stream.respond_to?(:call)
        MaquinaStream has no `find_stream` callable configured, so it cannot
        resolve stream id #{sid.inspect}. Set one:

          MaquinaStream.configure { |c| c.find_stream = ->(sid) { Message.find_by(id: sid) } }
      MESSAGE

      find_stream.call(sid)
    end

    # Host-owned authorization. Denies when the host has not configured a
    # callable — the engine never assumes it may serve a message.
    def authorized?(record, request)
      return false unless authorize.respond_to?(:call)

      !!authorize.call(record, request)
    end
  end
end
