# frozen_string_literal: true

module MaquinaStream
  class Renderer
    # Gives a **registered** app-meaning tag its own HTML block, by putting
    # blank lines around its opening and closing tags before commonmarker ever
    # sees the buffer.
    #
    # ```ruby
    # MaquinaStream::Renderer::TagBlocks.call(markdown, names: MaquinaStream.tags.keys)
    # ```
    #
    # ## The bug this exists for
    #
    # CommonMark ends an HTML block at the first blank line (spec §4.6,
    # condition 7). A tag a model wrote across several paragraphs therefore has
    # its closing tag emitted *inside a paragraph*:
    #
    # ```
    # <thinking>\nFirst para.\n\nSecond para.\n</thinking>\n\nAfter the tag.
    # #  <thinking>
    # #  First para.
    # #  <p>Second para.<br />\n</thinking></p>
    # #  <p>After the tag.</p>
    # ```
    #
    # The HTML5 parser sees a stray end tag, ignores it, and never closes
    # `<thinking>` — so the rest of the message is parsed *inside* it and the
    # host's partial is handed content the model wrote after the tag closed.
    # That is a content leak, not a cosmetic defect: the partial is where the
    # host says "this is the model's private reasoning".
    #
    # With a blank line after the opener and before the closer, each tag is its
    # own HTML block, the element closes where the model closed it, and the
    # paragraphs between them are ordinary markdown.
    #
    # ## Why it normalises markdown rather than HTML
    #
    # Rebalancing end tags in the commonmarker output would mean hand-editing an
    # HTML string that is model output — the one thing this engine never does.
    # This pass inserts newlines into the markdown and changes nothing else;
    # the trust boundary stays exactly where it was, with the sanitizer running
    # last over parsed HTML.
    #
    # ## What it will not touch
    #
    # It is a privilege boundary, and it is written to be boring:
    #
    # * **Only registered names.** `names:` is what the host passed to
    #   `MaquinaStream.register_tag`. An unregistered `<script>`, `<iframe>` or
    #   `<img>` is not matched, not moved and not re-parsed. With an empty
    #   registry the input is returned byte for byte.
    # * **Code wins.** Matching runs over MaquinaRemend::Scanner#masked_text,
    #   which blanks fenced code blocks and balanced inline code spans while
    #   preserving offsets, so a `<thinking>` inside a fence or a backtick span
    #   is text and stays text. Indented code is covered by the indent rule
    #   below rather than by the scanner, which does not track it, and the raw
    #   HTML regions the scanner does not model either — comments, `<script>`,
    #   `<pre>` and friends — are masked here by RAW_REGIONS.
    # * **Complete tags only.** A match is a whole open or close tag on one
    #   line, with CommonMark's attribute grammar — quoted values may contain
    #   `>`, and a tag broken across a newline is not a tag. `<thinkingXYZ>`
    #   does not match `thinking`; `<thinking/>` opens nothing.
    # * **Block position only.** The opening tag must *begin its line* under
    #   four columns of indent, which is the shape that starts an HTML block and
    #   therefore the shape that leaks. Anything deeper may be indented code or
    #   list content and is left alone; an inline `<citation>…</citation>` in
    #   the middle of a sentence is left alone because it already works, and is
    #   what the registry was built for.
    # * **Pairs only.** An opener with no closer, or a closer with no opener,
    #   inserts nothing. Nesting is matched innermost-first, as HTML does it.
    #
    # Insertion is idempotent: a buffer that already has the blank lines comes
    # back byte-identical, which is what makes the pass safe to run on every
    # frame of a stream.
    class TagBlocks
      # An HTML block opener may be indented up to three columns; the fourth
      # makes it indented code.
      MAX_INDENT = 3

      # An indent that still starts an HTML block, and one that is deep enough
      # to be indented code or list content instead.
      BLOCK_INDENT = /\A {0,#{MAX_INDENT}}\z/
      CODE_INDENT = /\A[ \t]{#{MAX_INDENT + 1},}\z/

      # CommonMark's attribute grammar (spec §6.6), restricted to spaces and
      # tabs. A tag whose attributes wrap onto a second line is not a complete
      # tag for HTML-block purposes, so it must not be one for us either.
      ATTRIBUTE = /[ \t]+[a-zA-Z_:][a-zA-Z0-9_.:-]*(?:[ \t]*=[ \t]*(?:[^ \t"'=<>`]+|'[^']*'|"[^"]*"))?/

      # The raw regions CommonMark reads to a closing marker rather than to a
      # blank line: HTML block types 1 through 5 — `<script>`, `<pre>`,
      # `<style>` and `<textarea>`, comments, processing instructions,
      # declarations and CDATA.
      #
      # MaquinaRemend::Scanner masks fences and inline code, which is the
      # markdown half of "this is text, not markup"; it does not model these,
      # because no repair it makes has ever needed to. They matter here for one
      # reason: a blank line inserted inside one of them **ends it early**, and
      # text the model had buried in a comment or a `<script>` — text the
      # sanitizer would have dropped whole — comes back out as live markdown.
      # Masking them means a registered name written inside one is never a tag.
      #
      # An unterminated region masks to the end of the buffer, which is the
      # conservative answer while a message is still streaming.
      RAW_REGIONS = [
        /<!--.*?(?:-->|\z)/m,
        /<!\[CDATA\[.*?(?:\]\]>|\z)/m,
        /<\?.*?(?:\?>|\z)/m,
        /<![A-Za-z].*?(?:>|\z)/m,
        %r{<(script|pre|style|textarea)\b.*?(?:</\1\s*>|\z)}mi
      ].freeze

      class << self
        # Normalises `markdown` for the given tag `names` and returns it.
        # Returns the argument unchanged when nothing is registered, when no
        # registered tag appears in block position, or when the blank lines are
        # already there.
        def call(markdown, names: MaquinaStream.tags.keys)
          new(names: names).call(markdown)
        end
      end

      # The registered tag names this instance will normalise, downcased.
      attr_reader :names

      def initialize(names:)
        @names = Array(names).map { |name| name.to_s.downcase }.reject(&:empty?).uniq
      end

      def call(markdown)
        return markdown if markdown.nil? || markdown.empty? || names.empty?

        insertions = plan(markdown.to_s)
        return markdown if insertions.empty?

        splice(markdown.to_s, insertions)
      end

      private
        # Longest first, so `<answer>` cannot be matched inside `<answerable>`
        # by a shorter alternative winning the alternation.
        def pattern
          @pattern ||= begin
            alternation = names.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }.join("|")
            /<(\/?)(#{alternation})(?![a-zA-Z0-9_:-])(#{ATTRIBUTE}*)[ \t]*(\/?)>/i
          end
        end

        # `[position, text]` pairs, one per newline this pass wants to insert.
        def plan(text)
          pairs(text).flat_map { |open, close| insertions_for(text, open, close) }.compact
        end

        # Matched open/close ranges, innermost first, over the masked buffer so
        # that code context is honoured. Mirrors the stack in
        # MaquinaRemend::Handlers::AppTags rather than inventing a second one.
        def pairs(text)
          masked = mask_raw_regions(MaquinaRemend::Scanner.new(text).masked_text)
          stack = []

          masked.to_enum(:scan, pattern).each_with_object([]) do |_, found|
            match = Regexp.last_match
            name = match[2].downcase
            range = match.begin(0)...match.end(0)

            if match[1].empty?
              # A self-closing `<citation id="1"/>` opens nothing.
              stack << [name, range] if match[4].empty?
            elsif (index = stack.rindex { |open_name, _| open_name == name })
              found << [stack[index][1], range]
              stack.slice!(index..)
            end
          end
        end

        # Blanks every RAW_REGIONS span, keeping the buffer's length so that
        # match offsets are still offsets into the original text. Same trick,
        # and the same masking character, as MaquinaRemend::Scanner.
        def mask_raw_regions(masked)
          RAW_REGIONS.reduce(masked) do |text, pattern|
            text.gsub(pattern) { MaquinaRemend::Scanner::MASK * ::Regexp.last_match(0).length }
          end
        end

        # Four questions per pair, each answering with one newline or with
        # nothing: is there a blank line above the opener, below the opener,
        # above the closer, below the closer. A pair that is not in block
        # position, or whose closer sits in what could be indented code, is
        # skipped entirely.
        def insertions_for(text, open, close)
          return [] unless block_positioned?(text, open)
          return [] unless closer_placeable?(text, close)

          [
            blank_line_before(text, open),
            blank_line_after(text, open),
            blank_line_before(text, close),
            blank_line_after(text, close)
          ]
        end

        # A registered tag that **begins a line** under four columns of indent is
        # the host's block-level component, and is the only shape this pass
        # touches. Anything else is either already correct — an inline
        # `<citation>…</citation>` in the middle of a sentence renders fine and
        # is left exactly as the model wrote it — or ambiguous, because four
        # columns could be indented code or list continuation, and ambiguous
        # means untouched.
        def block_positioned?(text, range)
          text[line_start(text, range.first)...range.first].match?(BLOCK_INDENT)
        end

        # The closer may carry prose in front of it — that is the common case,
        # `Second para.</thinking>` — but four columns of leading whitespace
        # could be indented code, and a repair there would corrupt it.
        def closer_placeable?(text, range)
          indent = text[line_start(text, range.first)...range.first]

          !indent.match?(CODE_INDENT)
        end

        # A blank line above the tag. Prose in front of it on the same line is
        # pushed down instead — `Second para.</thinking>` becomes two blocks —
        # and a tag that already has a blank line above it is left alone, which
        # is what makes the pass idempotent.
        def blank_line_before(text, range)
          start = line_start(text, range.first)
          head = text[start...range.first]

          return [range.first, "\n\n"] unless head.match?(/\A[ \t]*\z/)
          return nil if start.zero? || text[0...start].match?(/(?:\A|\n)[ \t]*\n\z/)

          [start, "\n"]
        end

        # A blank line below the tag, by the same rules. It matters on the
        # closer as much as on the opener: without it the text after
        # `</thinking>` continues the closer's HTML block and is emitted as raw
        # HTML instead of being rendered as the markdown the model wrote.
        def blank_line_after(text, range)
          tail = rest_of_line(text, range.last)

          return [range.last, "\n\n"] unless tail.match?(/\A[ \t]*\z/)

          following = text[(range.last + tail.length + 1)..]
          return nil if following.nil? || following.match?(/\A[ \t]*(?:\n|\z)/)

          [range.last, "\n"]
        end

        # `rindex` reads a negative start as an offset from the end of the
        # string, so offset 0 has to answer for itself rather than search.
        def line_start(text, offset)
          return 0 if offset.zero?

          (text.rindex("\n", offset - 1) || -1) + 1
        end

        def rest_of_line(text, offset)
          text[offset...(text.index("\n", offset) || text.length)].to_s
        end

        # Two pairs can ask for the same newline — a closer and the next
        # opener, say. Each position is written once, with the longest text
        # asked for there, so the pass stays idempotent.
        def splice(text, insertions)
          merged = insertions.group_by(&:first).transform_values { |group| group.map(&:last).max_by(&:length) }

          merged.keys.sort.reverse_each.with_object(+text) do |position, buffer|
            buffer.insert(position, merged[position])
          end
        end
    end
  end
end
