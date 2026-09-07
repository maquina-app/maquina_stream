# frozen_string_literal: true

module MaquinaStream
  # Every key documented in docs/configuration.md, with its documented default.
  #
  # Three keys are seams the engine cannot supply itself and that
  # docs/configuration.md names but that have no default the engine could pick:
  # `find_stream`, `authorize` and `transport`. See docs/repair.md.
  #
  # Reach it through MaquinaStream.configure, once, from an initializer:
  #
  # ```ruby
  # MaquinaStream.configure do |c|
  #   c.find_stream = ->(sid) { Message.find_by(id: sid) }
  #   c.authorize   = ->(record, request) { record.conversation.readable_by?(request) }
  # end
  # ```
  #
  # ## Host seams
  #
  # | Option | Default | Consequence of changing it |
  # |---|---|---|
  # | `find_stream` | `nil` | The callable that turns a stream id into a record. Unset, every repair request raises ConfigurationError. See #find_stream! |
  # | `authorize` | `nil` | The callable that decides whether a request may see a record. **Unset, every repair request is refused.** See #authorized? |
  # | `transport` | `:turbo_streams` | Which transport Broadcaster's default emitter uses. The seam exists so SSE is possible without the broadcaster knowing about it; `:turbo_streams` is the only value the engine ships. |
  #
  # ## Streaming cadence
  #
  # | Option | Default | Consequence of changing it |
  # |---|---|---|
  # | `frame_budget_ms` | `100` | How long frames coalesce before one goes out. See the table below — this one has a measured cost, and it depends on how the text arrives. |
  # | `seal_lag` | `2` | How many blocks must open after a block before it may freeze. Lower it and markdown's backwards reinterpretation — a paragraph becoming a heading when its underline arrives — freezes a block that was still moving. Raise it and more blocks stay in the patch set of every frame. See Document#sealed_blocks. |
  # | `keyframe_interval_ms` | `4000` | How often the client reconciles its DOM against the manifest. Lower it and drift is corrected sooner at the cost of one small request per interval per open message; the manifest is bounded by `manifest_window`, not by message length. |
  # | `manifest_window` | `50` | How many recent sealed blocks a manifest carries in full; everything older is covered by one rollup digest. This is what keeps the payload bounded by the window instead of by the message. See Manifest. |
  #
  # ### What `frame_budget_ms` costs
  #
  # It was 60, then 250, and is 100. Coalescing only saves bytes when frames
  # arrive faster than the budget, so what it costs depends entirely on how the
  # text arrives. Measured on a 20KB message, against the size of the rendered
  # document:
  #
  # | arrival | 60ms | 100ms | 150ms | 250ms |
  # |---|---|---|---|---|
  # | token, 4 chars / 25ms | 3.03x | 2.34x | 1.65x | 1.08x |
  # | batch, 40 chars / 200ms | 1.07x | 1.07x | 1.07x | 0.89x |
  # | step, 2000 chars / 1s | 1.17x | 1.17x | 1.17x | 1.17x |
  #
  # 250ms is the only column inside the 1.5x budget under token arrival, which
  # is why it was chosen first. Under the batched arrival this engine is built
  # for it buys nothing — and it silently merges two steps into one frame,
  # which costs the per-step feedback that is the point of streaming a step at
  # all. Hence 100ms.
  #
  # **A host whose model emits token by token pays 2.34x at the default and
  # should raise its own `frame_budget_ms`.** `test/broadcaster_test.rb` pins
  # all three rows, so the trade-off fails loudly rather than drifting.
  #
  # ## Presentation
  #
  # | Option | Default | Consequence of changing it |
  # |---|---|---|
  # | `locale` | `:es` | Fallback locale for the engine's own labels when `I18n.locale` is unset. Spanish is the engine's default; English is the secondary translation. |
  # | `components` | `:maquina` | `:maquina` resolves a component to `maquina_components` when that gem is installed and defines it. `:plain` forces the vendored Tailwind fallback even when the gem is present. See MaquinaStream::Components. |
  # | `themes` | `{light: "github.light", dark: "github.dark"}` | Rouge theme names for the two generated highlighting stylesheets. Changing them requires re-running `rake maquina_stream:themes`; an unknown name raises rather than falling back silently. See Themes. |
  # | `controls` | see DEFAULT_CONTROLS | Which interactive affordances render. Assigning a hash merges one level deep; `false` turns everything off. See #controls= and #control?. |
  #
  # Theme names are Rouge's own — the registry has `github.dark` and
  # `github.light`, not `github_dark`.
  #
  # ## URL hardening
  #
  # Read by Sanitizer, which is the last pass before any HTML leaves the
  # server. Every one of these loosens or tightens what a *model* may put in an
  # `href` or a `src`, and model output is prompt-injectable.
  #
  # | Option | Default | Consequence of changing it |
  # |---|---|---|
  # | `default_origin` | `nil` | Base for resolving relative URLs. `nil` leaves a relative URL relative. Set it and a relative URL becomes absolute against that origin, and is re-checked against `allowed_protocols` afterwards. |
  # | `allowed_protocols` | `%w[http https mailto]` | The only schemes that survive. Adding one admits every URL that spells it; the dangerous-scheme list is checked first and independently. |
  # | `allowed_link_prefixes` | `["*"]` | `"*"` allows any destination. Replace it with a list of prefixes and every link not starting with one is stripped of its href — the text stays. |
  # | `allowed_image_prefixes` | `["*"]` | Same, for images. An image whose src does not survive is removed entirely: a broken rectangle carrying an attacker-chosen `alt` is worse than nothing. |
  # | `allow_data_images` | `true` | Whether `data:` image URLs survive. Only base64 rasters ever do; `data:image/svg+xml` is a scriptable document wearing an image's MIME type and is refused whatever this is set to. |
  class Configuration
    # Every interactive control the engine offers, and its documented default.
    #
    # | Group | Controls |
    # |---|---|
    # | `code` | the copy and download buttons on a code block |
    # | `table` | copy, download and fullscreen on a table |
    # | `image` | the download affordance on an inline image |
    # | `attachment` | download and remove on an attachment |
    # | `suggestion` | the suggestion chip row as a whole |
    # | `link_safety` | the confirmation dialog on an outbound link (a flag, not a group) |
    #
    # A group is a hash of individually switchable controls; `link_safety` is a
    # single boolean because it has exactly one. Reads go through `control?`, so
    # both shapes answer the same question.
    #
    # ```ruby
    # config.controls = { code: { copy: false } }   # one control off, rest untouched
    # config.controls = false                       # everything off, wholesale
    # config.controls = true                        # everything back on
    # ```
    #
    # An assigned hash is merged onto the defaults one level deep, so a host
    # names only what it is changing and `controls` stays complete.
    DEFAULT_CONTROLS = {
      code: {copy: true, download: true},
      table: {copy: true, download: true, fullscreen: true},
      image: {download: true},
      attachment: {download: true, remove: true},
      suggestion: {enabled: true},
      link_safety: true
    }.freeze

    # A fresh, mutable copy of DEFAULT_CONTROLS. The nested group hashes are
    # duplicated, so a caller cannot mutate the frozen defaults through one.
    def self.default_controls
      DEFAULT_CONTROLS.transform_values { |value| value.is_a?(Hash) ? value.dup : value }
    end

    # Every control set to `state`. The single expression for "all of them".
    def self.controls_all(state)
      DEFAULT_CONTROLS.transform_values do |value|
        value.is_a?(Hash) ? value.transform_values { state } : state
      end
    end

    # The resolved control map: every group, every control, always complete.
    # Assign through #controls=; read through #control?.
    attr_reader :controls

    # Every option, read and written directly. What each one does, its default
    # and the consequence of changing it are in the tables on Configuration
    # itself; they are grouped there rather than repeated once per accessor.
    attr_accessor :frame_budget_ms, :keyframe_interval_ms, :seal_lag, :manifest_window,
      :locale, :components, :themes,
      :default_origin, :allowed_protocols,
      :allowed_link_prefixes, :allowed_image_prefixes,
      :allow_data_images,
      :find_stream, :authorize, :transport

    # A configuration holding every documented default. MaquinaStream.config
    # builds one lazily; a host rarely constructs one itself, though passing a
    # throwaway as `config:` is how most of this engine is tested.
    def initialize
      @frame_budget_ms = 100
      @keyframe_interval_ms = 4_000
      # How many recent sealed blocks a manifest carries in full. Everything
      # older is covered by one rollup digest, which is what keeps the payload
      # bounded by the window instead of by the message. See Manifest.
      @manifest_window = 50
      @seal_lag = 2
      @locale = :es
      @components = :maquina
      @themes = {light: "github.light", dark: "github.dark"}

      @default_origin = nil
      @allowed_protocols = %w[http https mailto]
      @allowed_link_prefixes = ["*"]
      @allowed_image_prefixes = ["*"]
      @allow_data_images = true

      @controls = self.class.default_controls

      # Host seams. The engine never guesses a record and never assumes it may
      # serve one: with no host callable configured, every request is refused.
      @find_stream = nil
      @authorize = nil
      @transport = :turbo_streams
    end

    # Sets which controls render.
    #
    # `false`/`nil`/`:none` turns every control off; `true`/`:all` turns every
    # control back on; a hash merges onto the defaults one group at a time, so
    # a host names only what it is changing.
    def controls=(value)
      @controls =
        case value
        when false, nil, :none then self.class.controls_all(false)
        when true, :all then self.class.controls_all(true)
        else
          self.class.default_controls.merge(value.to_h.symbolize_keys) do |_key, default, given|
            (default.is_a?(Hash) && given.is_a?(Hash)) ? default.merge(given.symbolize_keys) : given
          end
        end
    end

    # Whether one control, or a whole group, is enabled.
    #
    # ```ruby
    # config.control?(:code, :copy)   # => true
    # config.control?(:link_safety)   # => true
    # config.control?(:code)          # => true while any code control remains
    # ```
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

    # Resolves the record a request is about, by calling the configured
    # `find_stream`. Returns whatever that callable returns, `nil` included.
    #
    # Raises ConfigurationError when the host has not configured a finder: the
    # engine has no model to guess at, and a silent `nil` would look like a
    # missing record rather than a missing seam.
    def find_stream!(sid)
      raise ConfigurationError, <<~MESSAGE unless find_stream.respond_to?(:call)
        MaquinaStream has no `find_stream` callable configured, so it cannot
        resolve stream id #{sid.inspect}. Set one:

          MaquinaStream.configure { |c| c.find_stream = ->(sid) { Message.find_by(id: sid) } }
      MESSAGE

      find_stream.call(sid)
    end

    # Whether this request may see this record, per the host's `authorize`
    # callable. The callable receives `(record, request)`; its return value is
    # coerced to a boolean.
    #
    # **Returns false when the host has not configured a callable.** Unlike
    # #find_stream! this does not raise: denial is the safe answer, and the
    # engine never assumes it may serve a message.
    def authorized?(record, request)
      return false unless authorize.respond_to?(:call)

      !!authorize.call(record, request)
    end
  end
end
