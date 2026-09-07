# frozen_string_literal: true

module MaquinaStream
  # The component seam.
  #
  # Every component the engine renders resolves through here, so extracting a
  # vendored component into `maquina_components` is mechanical: publish the
  # partial in that gem, drop the name from VENDORED_COMPONENTS, done. No call
  # site changes. See docs/component-scope.md.
  #
  # ```ruby
  # MaquinaStream::Components.partial_for(:code_block, config: MaquinaStream.config)
  # # => "maquina_components/code_block"        when the gem defines it
  # # => "maquina_stream/components/code_block" otherwise
  # ```
  #
  # `maquina_components` is an optional dependency. Without it every component
  # renders its vendored plain-Tailwind fallback, and `config.components =
  # :plain` forces that even when the gem is installed.
  module Components
    # Where a component lives once it has been extracted.
    DESTINATION_PREFIX = "maquina_components"

    # Where the vendored copy lives while it is still ours.
    VENDORED_PREFIX = "maquina_stream/components"

    # Engine-owned components. Permanent; they never resolve to the gem, even
    # when a partial of the same name shows up there.
    ENGINE_OWNED = %i[shimmer source_citation].freeze

    # Probes an installed `maquina_components` for the destination partial.
    # A plain object rather than a stub: tests inject their own.
    class Library
      # Returns nil when the gem is absent, which is the whole point of the
      # optional dependency: absence is a value, not an error.
      def self.detect
        return nil unless defined?(::MaquinaComponents::Engine)

        new(::MaquinaComponents::Engine.root.join("app", "views"))
      end

      def initialize(view_root)
        @view_root = Pathname(view_root)
      end

      # True when the gem itself ships the destination partial. We probe the
      # exact path we would render, never a path we merely hope exists.
      def defines?(name)
        defined_names.include?(name.to_sym)
      end

      private

      def defined_names
        @defined_names ||= @view_root.glob("#{DESTINATION_PREFIX}/_*.html.erb")
          .map { |path| path.basename(".html.erb").to_s.delete_prefix("_").to_sym }
          .to_set
      end
    end

    class << self
      # The partial path to render for `name`.
      #
      # `library` is a seam: pass one in to test either side of the branch
      # without touching the load path.
      def partial_for(name, config: MaquinaStream.config, library: default_library)
        name = name.to_sym

        return vendored_partial(name) if engine_owned?(name)
        return vendored_partial(name) unless config.components == :maquina
        return vendored_partial(name) unless library&.defines?(name)

        "#{DESTINATION_PREFIX}/#{name}"
      end

      # True for a component that is vendored here and destined for the gem.
      def vendored?(name)
        MaquinaStream::VENDORED_COMPONENTS.include?(name.to_sym)
      end

      # True for a component that is permanently the engine's and never
      # resolves to the gem, even if a partial of the same name shows up
      # there.
      def engine_owned?(name)
        ENGINE_OWNED.include?(name.to_sym)
      end

      # True for any component this engine knows how to render, vendored or
      # engine-owned.
      def known?(name)
        vendored?(name) || engine_owned?(name)
      end

      # True when `name` renders from our own app/views right now.
      def fallback_active?(name, config: MaquinaStream.config, library: default_library)
        partial_for(name, config: config, library: library).start_with?(VENDORED_PREFIX)
      end

      # Asset paths for the components currently rendering from our app/views.
      # One stylesheet per component, and none for a component the gem is
      # serving — otherwise the day it ships we emit its selectors twice.
      def stylesheets(config: MaquinaStream.config, library: default_library)
        styled_components
          .select { |name| fallback_active?(name, config: config, library: library) }
          .map { |name| "#{VENDORED_PREFIX}/#{name}" }
      end

      # The components we actually ship a stylesheet for — a component with no
      # fallback markup yet has no fallback CSS to load either.
      def styled_components
        @styled_components ||= Pathname(__dir__).join("../../app/assets/stylesheets", VENDORED_PREFIX)
          .glob("*.css")
          .map { |path| path.basename(".css").to_s.to_sym }
          .sort
      end

      def default_library
        return @default_library if defined?(@default_library) && !@default_library.nil?

        @default_library = Library.detect
      end

      # Forgets the detected library. Only useful in tests.
      def reset_library!
        @default_library = nil
      end

      private

      def vendored_partial(name)
        "#{VENDORED_PREFIX}/#{name}"
      end
    end
  end
end
