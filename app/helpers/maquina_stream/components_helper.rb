# frozen_string_literal: true

module MaquinaStream
  # The view side of the component seam. Engine views and the render pipeline
  # call +component+; nothing renders a vendored partial by path.
  module ComponentsHelper
    # component(:code_block, lang: "ruby", source: raw, css_classes: "…")
    #
    # The partial is generic; the engine's DOM contract and labels are added
    # here, by MaquinaStream::Components::Contract. That is what lets a vendored
    # partial leave for maquina_components without carrying `data-ms-*` or the
    # `maquina_stream.*` locale namespace with it.
    def component(name, **locals, &block)
      config = maquina_stream_config
      partial = MaquinaStream::Components.partial_for(name, config: config)
      locals = MaquinaStream::Components::Contract.apply(name, locals, config: config)

      if block
        render(layout: partial, locals: locals, &block)
      else
        render(partial: partial, locals: locals)
      end
    end

    # Merges caller-supplied data attributes with the component's own.
    #
    # The component wins its identity keys — +component+, +variant+, +size+ and
    # anything ending in +_part+ — because those are what the CSS selects on.
    # +controller+ and +action+ concatenate, component tokens first. Every other
    # key belongs to the caller.
    def component_data(own, provided = nil)
      own = own.compact
      provided = (provided || {}).transform_keys { |key| key.to_s.tr("-", "_").to_sym }

      merged = provided.merge(own) do |key, caller_value, own_value|
        if %i[controller action].include?(key)
          [own_value, caller_value].compact.join(" ").strip
        else
          own_value
        end
      end

      merged.reject { |_, value| value.nil? }
    end

    # Same-shaped merge for the non-data attributes a caller passes through
    # +**html_options+, with +css_classes+ folded into +class+.
    def component_html_options(html_options, own_data: {}, css_classes: nil, base_classes: nil)
      options = html_options.dup
      provided_data = options.delete(:data) || options.delete("data")

      options[:data] = component_data(own_data, provided_data)
      classes = component_classes(base_classes, css_classes)
      options[:class] = classes if classes.present?
      options
    end

    def component_classes(*tokens)
      tokens.flatten.compact.map(&:to_s).reject(&:empty?).join(" ").presence
    end

    # Stylesheet paths for the components currently rendering from our own
    # app/views. Empty once maquina_components serves all of them.
    def component_stylesheets
      MaquinaStream::Components.stylesheets(config: maquina_stream_config)
    end

    def maquina_stream_config
      MaquinaStream.config
    end
  end
end
