# frozen_string_literal: true

module MaquinaStream
  # Every key documented in docs/api-surface.md, with its documented default.
  #
  # Three keys are seams the engine cannot supply itself and that
  # docs/api-surface.md names in prose but not in the configuration block:
  # +find_stream+, +authorize+ and +transport+. See docs/engine-contract.md.
  class Configuration
    # Every interactive control the engine offers, and its documented default.
    #
    #   code:        the copy and download buttons on a code block
    #   table:       copy, download and fullscreen on a table
    #   image:       the download affordance on an inline image
    #   attachment:  download and remove on an attachment
    #   suggestion:  the suggestion chip row as a whole
    #   link_safety: the confirmation dialog on an outbound link (a flag, not a group)
    #
    # A group is a hash of individually switchable controls; +link_safety+ is a
    # single boolean because it has exactly one. Reads go through +control?+, so
    # both shapes answer the same question.
    #
    #   config.controls = { code: { copy: false } }   # one control off, rest untouched
    #   config.controls = false                       # everything off, wholesale
    #   config.controls = true                        # everything back on
    #
    # An assigned hash is merged onto the defaults one level deep, so a host
    # names only what it is changing and +controls+ stays complete.
    DEFAULT_CONTROLS = {
      code:  { copy: true, download: true },
      table: { copy: true, download: true, fullscreen: true },
      image: { download: true },
      attachment: { download: true, remove: true },
      suggestion: { enabled: true },
      link_safety: true
    }.freeze

    def self.default_controls
      DEFAULT_CONTROLS.transform_values { |value| value.is_a?(Hash) ? value.dup : value }
    end

    # Every control set to +state+. The single expression for "all of them".
    def self.controls_all(state)
      DEFAULT_CONTROLS.transform_values do |value|
        value.is_a?(Hash) ? value.transform_values { state } : state
      end
    end

    attr_reader :controls

    attr_accessor :frame_budget_ms, :keyframe_interval_ms, :seal_lag,
                  :locale, :components, :themes,
                  :default_origin, :allowed_protocols,
                  :allowed_link_prefixes, :allowed_image_prefixes,
                  :allow_data_images,
                  :find_stream, :authorize, :transport

    def initialize
      @frame_budget_ms      = 60
      @keyframe_interval_ms = 4_000
      @seal_lag             = 2
      @locale               = :es
      @components           = :maquina
      @themes               = { light: "github.light", dark: "github.dark" }

      @default_origin         = nil
      @allowed_protocols      = %w[http https mailto]
      @allowed_link_prefixes  = ["*"]
      @allowed_image_prefixes = ["*"]
      @allow_data_images      = true

      @controls = self.class.default_controls

      # Host seams. The engine never guesses a record and never assumes it may
      # serve one: with no host callable configured, every request is refused.
      @find_stream = nil
      @authorize   = nil
      @transport   = :turbo_streams
    end

    # +false+/+:none+ turns every control off; +true+/+:all+ turns every control
    # back on; a hash merges onto the defaults one group at a time.
    def controls=(value)
      @controls =
        case value
        when false, nil, :none then self.class.controls_all(false)
        when true, :all        then self.class.controls_all(true)
        else
          self.class.default_controls.merge(value.to_h.symbolize_keys) do |_key, default, given|
            default.is_a?(Hash) && given.is_a?(Hash) ? default.merge(given.symbolize_keys) : given
          end
        end
    end

    # control?(:code, :copy) / control?(:link_safety)
    #
    # With no control name, answers whether the group has anything left enabled,
    # so a header that exists only to hold controls can be dropped whole.
    def control?(group, name = nil)
      value = controls[group.to_sym]

      case value
      when Hash then name.nil? ? value.values.any? { |enabled| !!enabled } : !!value[name.to_sym]
      else !!value
      end
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
