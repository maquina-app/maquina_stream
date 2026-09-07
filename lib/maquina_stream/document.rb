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
    def sealed_blocks
      blocks.first([blocks.length - config.seal_lag, 0].max)
    end

    def unsealed_blocks
      blocks.drop(sealed_blocks.length)
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
      def build_blocks
        rendered = Nokogiri::HTML5.fragment(html).children.select(&:element?)
        ranges = source_ranges
        sealed_count = [rendered.length - config.seal_lag, 0].max

        rendered.each_with_index.map do |node, index|
          range = ranges[index]

          Block.new(
            index: index,
            markdown: slice(range),
            html: node.to_html,
            line_range: range,
            sid: sid,
            sealed: index < sealed_count
          )
        end
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
          from > to ? (from..from) : (from..to)
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
