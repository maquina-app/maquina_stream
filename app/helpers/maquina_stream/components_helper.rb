# frozen_string_literal: true

module MaquinaStream
  # The view side of the component seam. Engine views and the render pipeline
  # call +component+; nothing renders a vendored partial by path.
  module ComponentsHelper
    # component(:code_block, lang: "ruby", source: raw, css_classes: "…")
    def component(name, **locals, &block)
      partial = MaquinaStream::Components.partial_for(name, config: maquina_stream_config)

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

    # Raw source destined for <script type="text/plain">.
    #
    # A script element is a raw-text element: the parser does not decode
    # entities inside it, so HTML-escaping would corrupt the source the copy
    # button hands back. The only sequence that can end the element is a
    # literal `</script`, so that is the only sequence we touch. `ms-code`
    # reverses it on read.
    def component_script_source(source)
      escaped = source.to_s.gsub(%r{</(script)}i) { "<\\/#{Regexp.last_match(1)}" }
      escaped.html_safe # rubocop:disable Rails/OutputSafety -- see the comment above
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
