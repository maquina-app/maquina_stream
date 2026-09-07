# frozen_string_literal: true

require "nokogiri"
require "uri"
require "set"

module MaquinaStream
  # Allowlist plus URL hardening. The last pass before output, and it runs
  # unconditionally.
  #
  #   MaquinaStream::Sanitizer.call(html, config: MaquinaStream.config) # => String
  #
  # The input is model output: hostile, prompt-injectable, and never trusted
  # because an earlier stage already looked at it. Nothing here is a cleanup
  # pass — an element or an attribute survives only by being named, and a URL
  # survives only by being re-parsed and re-checked. Everything else is
  # dropped, not escaped and kept.
  #
  # See docs/sanitizer.md.
  class Sanitizer
    # Elements that survive: rendered markdown, plus the wrappers the post-pass
    # adds around it.
    ALLOWED_ELEMENTS = %w[
      p div span br hr
      h1 h2 h3 h4 h5 h6
      ul ol li dl dt dd
      table thead tbody tfoot tr td th caption colgroup col
      pre code kbd samp var
      blockquote figure figcaption details summary section article aside
      a img
      em strong b i u s del ins mark small sub sup q abbr dfn cite time wbr
      input
    ].to_set.freeze

    # Removed with everything inside them. Unwrapping these would smuggle their
    # contents back into the document: script text, CSS, or a foreign-content
    # (SVG/MathML) subtree whose parsing rules are not HTML's.
    DROP_WITH_CONTENT = %w[
      script style svg math template noscript iframe frame frameset object
      embed applet param form button select option optgroup textarea label
      fieldset legend base link meta head title html body audio video source
      track canvas map area portal dialog marquee plaintext xmp listing
    ].to_set.freeze

    # `hidden` earns its place: the raw-source carrier is a hidden <pre>, and a
    # carrier that loses its hidden attribute renders every code block twice.
    GLOBAL_ATTRIBUTES = %w[id class title lang dir role translate hidden].to_set.freeze

    ELEMENT_ATTRIBUTES = {
      "a"        => %w[href target rel hreflang type],
      "img"      => %w[src alt width height loading decoding],
      "ol"       => %w[start reversed type],
      "li"       => %w[value],
      "td"       => %w[colspan rowspan align valign headers scope],
      "th"       => %w[colspan rowspan align valign headers scope abbr],
      "col"      => %w[span align],
      "colgroup" => %w[span align],
      "table"    => %w[align],
      "input"    => %w[type checked disabled],
      "time"     => %w[datetime],
      "details"  => %w[open]
    }.transform_values { |names| names.to_set.freeze }.freeze

    # The allowlist already excludes every one of these. Naming them keeps the
    # intent across refactors and gives the regression suite something explicit
    # to assert on.
    FORBIDDEN_ATTRIBUTES = %w[
      srcdoc formaction xlink:href xlink:show xlink:actuate xml:base
      style action background dynsrc lowsrc ping http-equiv srcset usemap
      accesskey contenteditable name
    ].to_set.freeze

    # Non-Stimulus data hooks our own partials emit.
    STATIC_DATA_ATTRIBUTES = %w[
      data-component data-variant data-size data-slot data-state data-side
      data-orientation data-controller data-action data-turbo-permanent
      data-turbo-temporary
    ].to_set.freeze

    DATA_ATTRIBUTE_SHAPE = /\Adata-[a-z0-9]+(?:-[a-z0-9]+)*\z/

    # Component internals: data-code-block-part, data-shimmer-part and friends.
    # They carry no behaviour, only styling hooks for a component's own parts.
    COMPONENT_PART_ATTRIBUTE = /\Adata-[a-z0-9]+(?:-[a-z0-9]+)*-part\z/
    ARIA_ATTRIBUTE_SHAPE = /\Aaria-[a-z]+\z/

    # Only our own controller namespace. A host or third-party identifier
    # arriving inside model output has no business being instantiated.
    CONTROLLER_IDENTIFIER = /\Ams-[a-z0-9]+(?:-[a-z0-9]+)*\z/
    ACTION_DESCRIPTOR = %r{
      \A
      (?:[a-zA-Z0-9:.\-]+(?:@[a-z]+)?->)?
      ms-[a-z0-9-]+\#[a-zA-Z_][a-zA-Z0-9_]*
      (?::[a-z]+)*
      \z
    }x

    # Rejected however they are spelled, including after the decoding a browser
    # would do on our behalf.
    DANGEROUS_SCHEMES = %w[
      javascript livescript vbscript jscript mocha data file blob about jar
      view-source chrome chrome-extension resource feed ms-its
    ].to_set.freeze

    # Control characters, and the whitespace a browser strips before it reads
    # the scheme. Removing them first means the scheme we test is the scheme
    # the browser will act on.
    URL_NOISE = /[\u0000-\u0020\u007F-\u00A0\u1680\u180E\u2000-\u200F\u2028\u2029\u202F\u205F\u3000\uFEFF]/

    DATA_IMAGE = %r{
      \Adata:image/(?:png|jpe?g|gif|webp|avif|bmp|x-icon|vnd\.microsoft\.icon)
      ;base64,[A-Za-z0-9+/=]+\z
    }xi

    class << self
      def call(html, config: MaquinaStream.config)
        new(config: config).call(html)
      end
    end

    attr_reader :config

    def initialize(config: MaquinaStream.config)
      @config = config || MaquinaStream.config
    end

    def call(html)
      return "" if html.nil?

      source = html.to_s
      return "" if source.empty?

      fragment = parse(source)
      scrub_children(fragment)
      fragment.to_html
    end

    private
      # HTML5 parsing wherever Nokogiri offers it. The HTML4 parser's error
      # recovery is not any browser's, and a sanitizer that parses a document
      # differently from the engine that will display it is a mutation XSS
      # waiting for its input.
      def parse(html)
        if defined?(Nokogiri::HTML5)
          Nokogiri::HTML5.fragment(html)
        else
          Nokogiri::HTML::DocumentFragment.parse(html)
        end
      end

      def scrub_children(node)
        node.children.to_a.each { |child| scrub_node(child) }
      end

      def scrub_node(node)
        if node.element?
          scrub_element(node)
        elsif node.cdata?
          # A parser artifact. Its characters are inert once they are text and
          # the serializer escapes them.
          node.replace(Nokogiri::XML::Text.new(node.content, node.document))
        elsif !node.text?
          # Comments, processing instructions, doctypes. A conditional comment
          # is script delivery in a costume.
          node.unlink
        end
      end

      def scrub_element(node)
        name = node.name.downcase

        return node.unlink if DROP_WITH_CONTENT.include?(name) || foreign?(node)
        return unwrap(node) unless ALLOWED_ELEMENTS.include?(name)

        scrub_attributes(node, name)
        return unless node.parent # an element rule may have removed the node

        scrub_children(node)
      end

      # SVG and MathML subtrees arrive through foreign-content parsing rules,
      # where `<style>` and `<annotation-xml>` re-enter HTML parsing. Nothing in
      # rendered markdown needs either namespace.
      def foreign?(node)
        href = node.namespace&.href.to_s
        href.include?("svg") || href.include?("MathML")
      end

      def unwrap(node)
        scrub_children(node)
        children = node.children
        children.empty? ? node.unlink : node.replace(children)
      end

      def scrub_attributes(node, name)
        node.attribute_nodes.each do |attr|
          attr_name = attr.name.downcase
          qualified = attr.namespace ? "#{attr.namespace.prefix}:#{attr_name}" : attr_name

          # Namespaced attributes (xlink:href, xml:base) never survive: an
          # allowlist for them would have to be a second allowlist.
          next attr.unlink if attr.namespace
          next attr.unlink if FORBIDDEN_ATTRIBUTES.include?(qualified)
          next attr.unlink unless allowed_attribute?(name, attr_name)

          scrub_attribute_value(node, name, attr, attr_name)
        end

        enforce_element_rules(node, name)
      end

      def allowed_attribute?(element, attr_name)
        return false if attr_name.start_with?("on")
        return data_attribute?(attr_name) if attr_name.start_with?("data-")
        return true if attr_name.match?(ARIA_ATTRIBUTE_SHAPE)
        return true if GLOBAL_ATTRIBUTES.include?(attr_name)

        ELEMENT_ATTRIBUTES.fetch(element, Set[]).include?(attr_name)
      end

      # `data-ms-*` is ours, and so is every Stimulus value, target, class,
      # param and outlet derived from an `ms-` identifier. Anything else,
      # a third-party controller's values included, is dropped.
      def data_attribute?(attr_name)
        return false unless attr_name.match?(DATA_ATTRIBUTE_SHAPE)
        return true if attr_name.start_with?("data-ms-")
        return true if attr_name.match?(COMPONENT_PART_ATTRIBUTE)

        STATIC_DATA_ATTRIBUTES.include?(attr_name)
      end

      def scrub_attribute_value(node, name, attr, attr_name)
        case attr_name
        when "href", "src"
          harden_url(node, name, attr, attr_name)
        when "data-controller"
          filter_tokens(attr) { |token| token.match?(CONTROLLER_IDENTIFIER) }
        when "data-action"
          filter_tokens(attr) { |token| token.match?(ACTION_DESCRIPTOR) }
        when "target"
          attr.value = "_blank" unless %w[_blank _self].include?(attr.value)
        end
      end

      def filter_tokens(attr)
        kept = attr.value.to_s.split(/\s+/).reject(&:empty?).select { |token| yield token }
        kept.empty? ? attr.unlink : attr.value = kept.join(" ")
      end

      def harden_url(node, name, attr, attr_name)
        kind = (name == "img" || attr_name == "src") ? :image : :link
        safe = safe_url(attr.value, kind: kind)

        return attr.value = safe if safe

        attr.unlink
        # An image with no source is a broken rectangle carrying an
        # attacker-chosen alt string. A link with no href still shows its text.
        node.unlink if name == "img"
      end

      def safe_url(raw, kind:)
        url = raw.to_s.gsub(URL_NOISE, "")
        return nil if url.empty?
        return url if url.start_with?("#") # same-document fragment

        # `//evil.example`, and the backslash spellings browsers normalize into
        # it, inherit the page's scheme and none of its origin.
        return nil if url.match?(%r{\A[\\/]{2}}) || url.start_with?("\\")

        scheme = scheme_of(url)
        decoded_scheme = scheme_of(decode(url))

        # A scheme that only appears once the browser decodes (`%6Aavascript:`,
        # `java&#115;cript:` double-encoded) is still a scheme.
        return nil if decoded_scheme && decoded_scheme != scheme && DANGEROUS_SCHEMES.include?(decoded_scheme)

        if scheme
          return kind == :image ? data_image_url(url) : nil if scheme == "data"
          return nil unless allowed_protocols.include?(scheme)
        else
          url = resolve(url)
          return nil if url.nil?
        end

        allowed_prefix?(url, kind: kind) ? url : nil
      end

      def scheme_of(url)
        match = /\A([a-zA-Z][a-zA-Z0-9+.\-]*):/.match(url)
        match && match[1].downcase
      end

      # What a browser is left with after entity decoding (the HTML parser has
      # usually done one round already; double-encoded payloads survive it) and
      # after percent decoding.
      def decode(url)
        decoded = url.gsub(/&#x([0-9a-fA-F]+);?/) { [Regexp.last_match(1).hex].pack("U") }
        decoded = decoded.gsub(/&#(\d+);?/) { [Regexp.last_match(1).to_i].pack("U") }
        decoded = decoded.gsub(/%([0-9a-fA-F]{2})/) { [Regexp.last_match(1)].pack("H2") }
        decoded.force_encoding(Encoding::UTF_8).gsub(URL_NOISE, "")
      rescue ArgumentError, RangeError
        url
      end

      # Base64 raster images only. `data:image/svg+xml` is a scriptable
      # document wearing an image's MIME type.
      def data_image_url(url)
        return nil unless allow_data_images?
        return nil unless url.match?(DATA_IMAGE)

        url
      end

      def resolve(url)
        origin = config.default_origin
        return url if origin.nil? || origin.to_s.empty?

        joined = URI.join(origin.to_s, url).to_s
        allowed_protocols.include?(scheme_of(joined).to_s) ? joined : nil
      rescue URI::Error
        nil
      end

      def allowed_prefix?(url, kind:)
        prefixes = Array(kind == :image ? config.allowed_image_prefixes : config.allowed_link_prefixes)
        return true if prefixes.empty? || prefixes.include?("*")

        prefixes.any? { |prefix| url.start_with?(prefix.to_s) }
      end

      def allowed_protocols
        @allowed_protocols ||= Array(config.allowed_protocols).map { |p| p.to_s.downcase.delete_suffix(":") }
      end

      def allow_data_images?
        !!config.allow_data_images
      end

      def enforce_element_rules(node, name)
        case name
        when "input"
          # The tasklist extension's disabled checkbox, and nothing else.
          node["type"].to_s.downcase == "checkbox" ? node["disabled"] = "disabled" : node.unlink
        when "a"
          harden_link(node)
        end
      end

      def harden_link(node)
        return unless node["href"]

        rel = node["rel"].to_s.split(/\s+/) | %w[noopener noreferrer]
        node["rel"] = rel.reject(&:empty?).join(" ")
      end
  end
end
