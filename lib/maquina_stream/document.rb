# frozen_string_literal: true

module MaquinaStream
  # Splits a rendered message into top-level blocks, and decides which of them
  # are safe to freeze.
  #
  # ```ruby
  # document = MaquinaStream::Document.new(markdown, config: config, sid: "m8f21")
  # document.blocks          # every top-level block, in order
  # document.sealed_blocks   # frozen, never re-sent
  # document.open_block      # the tail, patched on every frame
  # ```
  #
  # The whole buffer is rendered once and then sliced. Blocks are never rendered
  # in isolation: a block that mentions [docs] needs the link reference
  # definition that lives at the bottom of the message, and rendering it alone
  # silently loses it.
  class Document
    # The raw markdown this document was built from.
    attr_reader :markdown

    # The Configuration it reads — `seal_lag` in particular.
    attr_reader :config

    # The stream id every block id is prefixed with, or nil for an anonymous
    # render.
    attr_reader :sid

    # The render mode passed through to Renderer, one of Renderer::MODES.
    attr_reader :mode

    # Builds a document over one markdown buffer.
    #
    # `sid:` is the record's `maquina_stream_id`. Pass it: block ids are built
    # from it, and a document rendered without one produces ids
    # (`ms-b0`, `ms-b1`) that collide the moment two messages share a page.
    #
    # Nothing is rendered until #blocks or #html is called.
    def initialize(markdown, config: MaquinaStream.config, sid: nil, mode: :streaming)
      @markdown = markdown.to_s
      @config = config
      @sid = sid
      @mode = mode
    end

    # Every top-level Block, in document order, each already stamped with its
    # id and digest. Memoized: the whole buffer is rendered once, on the first
    # call.
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

    # The blocks behind the seal pointer: still able to change, and therefore
    # still eligible for a patch on the next frame.
    def unsealed_blocks
      blocks.drop(seal_pointer)
    end

    # How far sealing reached, as an index into #blocks. Sealing is a prefix,
    # so this is both the count of sealed blocks and the position of the first
    # unsealed one.
    def seal_pointer
      @seal_pointer ||= blocks.count(&:sealed?)
    end

    # The last block — the tail the model is currently writing into.
    def open_block
      blocks.last
    end

    # The whole document as one rendered HTML string, before it is sliced into
    # blocks. Memoized.
    def html
      @html ||= Renderer.call(markdown, mode: mode, config: config)
    end

    # `[[id, digest], …]` for the sealed blocks. What Manifest is built from.
    def manifest_entries
      sealed_blocks.map(&:to_manifest_entry)
    end

    private
      # Blocks are matched to their source range by the index the post-pass
      # stamped on them, never by position in the rendered output. The sanitizer
      # drops nodes - an HTML comment, a disallowed element - and a positional
      # match silently shifts every range after the first drop.
      def build_blocks
        rendered = block_nodes(Nokogiri::HTML5.fragment(html))
        ranges = source_ranges
        indices = block_indices(rendered)
        sealed_count = [rendered.length - config.seal_lag, 0].max

        rendered.each_with_index.map do |node, position|
          source_index = indices[position]
          range = ranges[source_index]

          # The digest covers the block's content, before the element-level
          # attributes below are stamped on. Those change when a block seals or
          # when the caret moves past it, and neither changes what it says.
          digest = Digest::SHA256.hexdigest("#{source_index}:#{node.inner_html}")[0, 16]

          # The DOM contract, from docs/javascript.md. The id is index-derived
          # so idiomorph pairs the node instead of recreating it.
          node["id"] = sid ? "ms-#{sid}-b#{source_index}" : "ms-b#{source_index}"
          node["data-ms-block"] = ""
          node["data-ms-block-index"] = source_index.to_s
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

      # Inline-level elements. Content inside a block, never a block of their
      # own — and every one of them can be stranded at the top level by the
      # unwrap below.
      INLINE_ELEMENTS = Set[
        "a", "abbr", "b", "br", "cite", "code", "del", "dfn", "em", "i", "img",
        "input", "ins", "kbd", "mark", "q", "s", "samp", "small", "span",
        "strong", "sub", "sup", "time", "u", "var", "wbr"
      ]

      # Splitting must not be able to lose a character.
      #
      # The sanitizer unwraps an element it does not know — <thinking>,
      # <tool_call>, <citation>, any tag a model invents to carry meaning for the
      # application — and keeps its children. CommonMark has already made that
      # tag an HTML block, so the text under it comes back as a bare text node at
      # the TOP level of the fragment, where `select(&:element?)` used to drop it
      # on the floor. The same happens to an inline element the unwrap strands
      # there.
      #
      # The wrapping belongs here rather than in the sanitizer's final pass. The
      # sanitizer is a pure allowlist over an arbitrary fragment: it runs again
      # on the client over fragments that are deliberately inline, and a pass
      # that invented a <p> around them would change what the caller asked to
      # sanitize. Document is the object that claims every character which
      # survives sanitizing lands in exactly one block, so it is the object that
      # has to make the claim true.
      #
      # Consecutive orphans are wrapped together — text plus the <em> beside it
      # stay one block, as they read — and a run that is only whitespace is
      # inter-block separation, not content, so it is left where it is.
      def block_nodes(fragment)
        fragment.children.to_a
          .slice_when { |before, after| orphan?(before) != orphan?(after) }
          .flat_map { |run| orphan?(run.first) ? [wrap_orphans(run)].compact : run.select(&:element?) }
      end

      def orphan?(node)
        return true unless node.element?

        INLINE_ELEMENTS.include?(node.name.downcase)
      end

      def wrap_orphans(run)
        return nil if run.map(&:text).join.strip.empty?

        wrapper = Nokogiri::XML::Node.new("p", run.first.document)
        wrapper["data-ms-element"] = "p"
        run.first.add_previous_sibling(wrapper)
        run.each { |node| wrapper.add_child(node) }
        wrapper
      end

      # The post-pass stamps `data-ms-block-index` on every top-level element it
      # sees; a block wrapped above never passed under it, and neither did an
      # element the unwrap promoted from inside one. Those take the first free
      # index at or after their position, so ids stay unique — the one property
      # idiomorph needs from them. They are not always in ascending order, and
      # they do not have to be: block order is the order of #blocks.
      def block_indices(nodes)
        used = nodes.filter_map { |node| node["data-ms-block-index"]&.to_i }.to_set
        cursor = 0

        nodes.each_with_index.map do |node, position|
          stamped = node["data-ms-block-index"]&.to_i
          next stamped if stamped

          cursor = [cursor, position].max
          cursor += 1 while used.include?(cursor)
          used << cursor
          cursor
        end
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
          prepared,
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

      # The same string the renderer parsed: repaired by maquina_remend and
      # normalised by Renderer::TagBlocks. Ranges and slices have to share one
      # coordinate system, and the rendered document is in this one.
      def prepared
        @prepared ||= Renderer.prepare(markdown)
      end

      def lines
        @lines ||= prepared.lines
      end

      def line_count = lines.length

      def slice(range)
        return "" unless range

        lines[(range.first - 1)..(range.last - 1)].to_a.join
      end
  end
end
