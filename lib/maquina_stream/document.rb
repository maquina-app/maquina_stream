# frozen_string_literal: true

module MaquinaStream
  # Splits a rendered message into top-level blocks, and decides which of them
  # are safe to freeze.
  #
  #   document = MaquinaStream::Document.new(markdown, config: config)
  #   document.sealed_blocks   # frozen, never re-sent
  #   document.open_block      # the tail, patched on every frame
  #
  # The whole buffer is rendered once and then sliced. Blocks are never rendered
  # in isolation: a block that mentions [docs] needs the link reference
  # definition that lives at the bottom of the message, and rendering it alone
  # silently loses it.
  class Document
    attr_reader :markdown, :config, :sid, :mode

    def initialize(markdown, config: MaquinaStream.config, sid: nil, mode: :streaming)
      @markdown = markdown.to_s
      @config = config
      @sid = sid
      @mode = mode
    end

    def blocks
      @blocks ||= build_blocks
    end

    # Sealed blocks trail the tail by config.seal_lag. Markdown reinterprets
    # retroactively - a paragraph becomes a heading when its underline arrives,
    # a table's delimiter row turns the line above into a header - so a block is
    # only safe to freeze once enough later blocks exist that nothing can reach
    # back into it.
    #
    # The lag is not the whole story. A link reference definition resolves links
    # in blocks arbitrarily far above it, so no fixed lag makes a block with an
    # unresolved reference safe. The pointer stops there instead, and moves on
    # once the definition arrives.
    def sealed_blocks
      blocks.first(seal_pointer)
    end

    def unsealed_blocks
      blocks.drop(seal_pointer)
    end

    def seal_pointer
      @seal_pointer ||= blocks.count(&:sealed?)
    end

    def open_block
      blocks.last
    end

    def html
      @html ||= Renderer.call(markdown, mode: mode, config: config)
    end

    def manifest_entries
      sealed_blocks.map(&:to_manifest_entry)
    end

    private
      # Blocks are matched to their source range by the index the post-pass
      # stamped on them, never by position in the rendered output. The sanitizer
      # drops nodes - an HTML comment, a disallowed element - and a positional
      # match silently shifts every range after the first drop.
      def build_blocks
        rendered = Nokogiri::HTML5.fragment(html).children.select(&:element?)
        ranges = source_ranges
        sealed_count = [rendered.length - config.seal_lag, 0].max

        rendered.each_with_index.map do |node, position|
          source_index = node["data-ms-block-index"]&.to_i || position
          range = ranges[source_index]

          # The digest covers the block's content, before the element-level
          # attributes below are stamped on. Those change when a block seals or
          # when the caret moves past it, and neither changes what it says.
          digest = Digest::SHA256.hexdigest("#{source_index}:#{node.inner_html}")[0, 16]

          # The DOM contract, from docs/api-surface.md. The id is index-derived
          # so idiomorph pairs the node instead of recreating it.
          node["id"] = sid ? "ms-#{sid}-b#{source_index}" : "ms-b#{source_index}"
          node["data-ms-block"] = ""
          node["data-ms-block-digest"] = digest

          Block.new(
            index: source_index,
            markdown: slice(range),
            html: node.to_html,
            line_range: range,
            sid: sid,
            sealed: false,
            digest: digest
          )
        end.then { |built| apply_seal(built, sealed_count) }
      end

      # Sealing is a prefix: the pointer is the position it reaches, so a block
      # that cannot seal holds every block after it open too.
      def apply_seal(built, sealed_count)
        limit = [sealed_count, unresolved_position(built) || sealed_count].min
        built.each_with_index.map { |block, position| (position < limit) ? block.seal : block }
      end

      def unresolved_position(built)
        built.index { |block| unresolved_references?(block.markdown) }
      end

      REFERENCE_USE = /\[[^\]\n]*\]\[([^\]\n]*)\]/
      # A definition counts only once its line is complete: "[docs]:" with no
      # destination yet resolves nothing, and "[docs]: https://exa" resolves to
      # a truncated host that changes when the rest arrives. Either would seal a
      # block whose links are still moving.
      REFERENCE_DEFINITION = /^ {0,3}\[([^\]\n]+)\]:[ \t]*\S+[^\n]*\n/

      def unresolved_references?(source)
        source.scan(REFERENCE_USE).flatten.any? do |label|
          !defined_reference_labels.include?(label.strip.downcase)
        end
      end

      def defined_reference_labels
        @defined_reference_labels ||= markdown.scan(REFERENCE_DEFINITION).flatten.map { |l| l.strip.downcase }.to_set
      end

      # Line ranges come from a parse of the raw buffer, not from the rendered
      # output: the post-pass rewrites elements and the sanitizer may drop one,
      # and neither carries a source position afterwards.
      #
      # HTML blocks report no sourcepos at all (confirmed against commonmarker
      # 2.10.0 in test/sourcepos_test.rb), and a link reference definition
      # renders no element whatsoever - so coverage has gaps, and a block with no
      # range of its own inherits the lines between its neighbours.
      def source_ranges
        parsed = Commonmarker.to_html(
          MaquinaRemend.call(markdown),
          options: Renderer::COMMONMARKER_OPTIONS,
          plugins: Renderer::COMMONMARKER_PLUGINS
        )

        nodes = Nokogiri::HTML5.fragment(parsed).children.select(&:element?)
        explicit = nodes.map { |node| parse_sourcepos(node["data-sourcepos"]) }

        fill_gaps(explicit)
      end

      def parse_sourcepos(value)
        return nil unless value

        start_line, end_line = value.split("-").map { |part| part.split(":").first.to_i }
        (start_line..end_line)
      end

      def fill_gaps(ranges)
        ranges.each_with_index.map do |range, index|
          next range if range

          previous_end = ranges[0...index].compact.last&.last
          next_start = ranges[(index + 1)..].compact.first&.first

          from = (previous_end || 0) + 1
          to = (next_start || line_count + 1) - 1
          (from > to) ? (from..from) : (from..to)
        end
      end

      def lines
        @lines ||= markdown.lines
      end

      def line_count = lines.length

      def slice(range)
        return "" unless range

        lines[(range.first - 1)..(range.last - 1)].to_a.join
      end
  end
end
