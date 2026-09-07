# frozen_string_literal: true

# Deliberately does NOT require test_helper: this probes commonmarker itself and
# must stay runnable without booting the dummy Rails host.
require "minitest/autorun"
require "commonmarker"
require "nokogiri"

# Runtime answers to the three questions left open by docs/spike-sourcepos.md.
#
# These assert what commonmarker 2.10.0 actually does, not what the spike hoped
# it would do. Two findings contradict the doc and are asserted deliberately:
# HTML blocks carry no data-sourcepos in rendered output, and the Route B method
# names recorded from source inspection do not exist.
class SourceposTest < Minitest::Test
  # Rendered-HTML options. `unsafe: true` so raw HTML blocks reach the output at
  # all; without it comrak replaces them with a comment.
  RENDER = {render: {sourcepos: true, unsafe: true}}.freeze

  # Plugins default to a syntect syntax highlighter that rewrites code block
  # innards into inline-styled spans. The splitter cares about the block
  # envelope, not the highlighting, so turn it off where it only adds noise.
  NO_HIGHLIGHT = {syntax_highlighter: nil}.freeze

  def test_commonmarker_version_under_test
    assert_equal "2.10.0", Commonmarker::VERSION
  end

  # --- Question 1 ------------------------------------------------------------
  # Does an unterminated fenced code block still report a sourcepos end line?
  # Yes. The end line is the last line that has content.

  def test_unterminated_fence_reports_an_end_line
    html = Commonmarker.to_html("intro\n\n```ruby\nputs 1\nputs 2\n",
      options: RENDER, plugins: NO_HIGHLIGHT)

    assert_includes html, %(<p data-sourcepos="1:1-1:5">intro</p>)
    # Fence opens on line 3; the last content line is 5 ("puts 2", 6 columns).
    assert_includes html, %(data-sourcepos="3:1-5:6")
  end

  def test_unterminated_fence_end_line_is_the_last_content_line_not_the_fence
    open_pos = code_block_position("```ruby\nputs 1\n")
    closed_pos = code_block_position("```ruby\nputs 1\n```\n")

    assert_equal 2, open_pos[:end_line], "open fence ends on its last content line"
    assert_equal 3, closed_pos[:end_line], "closed fence ends on the closing fence line"

    # Consequence for the splitter: sourcepos alone cannot tell an open block
    # from a closed one. Both report an end line; only the source text at that
    # line says whether a closing fence is there.
    refute_equal open_pos[:end_line], closed_pos[:end_line]
  end

  def test_degenerate_open_fences_still_report_a_position
    {
      "```ruby\n" => {end_line: 1, end_column: 7}, # fence opened, no content
      "```" => {end_line: 1, end_column: 3}, # bare fence, no newline
      "```ru" => {end_line: 1, end_column: 5}  # fence info still arriving
    }.each do |markdown, expected|
      pos = code_block_position(markdown)

      assert_equal 1, pos[:start_line], markdown.inspect
      assert_equal expected[:end_line], pos[:end_line], markdown.inspect
      assert_equal expected[:end_column], pos[:end_column], markdown.inspect
    end
  end

  def test_open_fence_is_still_typed_as_a_fenced_code_block_with_its_info_string
    node = Commonmarker.parse("```ruby\nputs 1\n").first

    assert_equal :code_block, node.type
    assert_predicate node, :fenced?
    assert_equal "ruby", node.fence_info
  end

  # --- Question 2 ------------------------------------------------------------
  # Are data-sourcepos ranges present on EVERY top-level block type?
  # No. Every block type carries one EXCEPT an HTML block, which is emitted
  # verbatim and therefore has nowhere for comrak to hang the attribute.

  def test_every_top_level_block_except_html_carries_data_sourcepos
    positions = top_level_positions(kitchen_sink)

    expected = [
      ["h1", "1:1-1:9"],
      ["p", "3:1-3:14"],
      ["blockquote", "5:1-6:13"],
      ["ul", "8:1-9:10"],
      ["ol", "11:1-12:9"],
      ["table", "14:1-16:9"],
      ["pre", "18:1-20:3"],
      ["pre", "22:5-23:0"],
      ["hr", "24:1-24:3"],
      ["div", nil], # <- the HTML block. No sourcepos.
      ["ul", "30:1-31:10"],
      ["p", "33:1-33:25"],
      ["p", "37:1-38:13"],
      ["p", "40:1-40:16"],
      ["section", "42:1-42:14"]
    ]

    assert_equal expected, positions
  end

  def test_html_block_has_no_sourcepos_in_rendered_output
    html = Commonmarker.to_html("para\n\n<div class=\"raw\">\nhtml block\n</div>\n\ntail\n",
      options: RENDER)

    div = Nokogiri::HTML5.fragment(html).children.find { it.element? && it.name == "div" }

    refute_nil div
    assert_nil div["data-sourcepos"],
      "comrak passes raw HTML blocks through untouched, so no attribute is injected"
  end

  def test_html_block_does_have_a_sourcepos_via_the_node_api
    node = Commonmarker.parse("para\n\n<div class=\"raw\">\nhtml block\n</div>\n\ntail\n")
      .find { it.type == :html_block }

    refute_nil node
    assert_equal({start_line: 3, start_column: 1, end_line: 5, end_column: 6},
      node.source_position)
  end

  def test_link_reference_definitions_produce_no_element_at_all
    html = Commonmarker.to_html("see [r][r]\n\n[r]: https://example.com\n", options: RENDER)
    elements = Nokogiri::HTML5.fragment(html).children.select(&:element?)

    assert_equal ["p"], elements.map(&:name)
    # The definition is consumed by the parser. A splitter that maps rendered
    # blocks back to line ranges will find lines 3..3 unclaimed by any element.
    assert_equal "1:1-1:10", elements.first["data-sourcepos"]
  end

  def test_route_b_method_names_recorded_by_source_inspection_do_not_exist
    node = Commonmarker.parse("```ruby\nputs 1\n```\n").first

    %i[get_sourcepos get_fenced get_fence_info get_first_child get_next_sibling
      get_parent type_to_symbol get_literal get_string_content].each do |absent|
      refute_respond_to node, absent
    end

    %i[source_position fenced? fence_info first_child next_sibling parent type
      literal string_content].each do |present|
      assert_respond_to node, present
    end
  end

  # --- Question 3 ------------------------------------------------------------
  # Does parse: { sourcepos_chars: true } behave as expected with CJK and emoji
  # sharing a line with markup? Yes, and precisely: columns become Ruby
  # String#length offsets, which is exactly what String#[] indexes by.

  def test_sourcepos_chars_switches_columns_from_bytes_to_characters
    line = "日本語 **強調** 🎉 tail"

    assert_equal 17, line.length
    assert_equal 30, line.bytesize

    assert_equal "1:1-1:30", paragraph_position(line, chars: false)
    assert_equal "1:1-1:17", paragraph_position(line, chars: true)
  end

  def test_char_columns_slice_correctly_where_byte_columns_do_not
    line = "日本語 **強調** 🎉 tail"

    # The <strong> span, sliced with Ruby's character-based String#[].
    assert_equal "**強調**", slice_by_columns(line, "1:5-1:10")

    # The same span's byte columns fed to the same slicer: silent garbage, no
    # exception. This is the off-by-N class sourcepos_chars removes.
    refute_equal "**強調**", slice_by_columns(line, "1:11-1:20")
    assert_equal " 🎉 tail", slice_by_columns(line, "1:11-1:20")
  end

  def test_inline_node_columns_shift_too_not_just_block_columns
    md = "日本語 **強調** 🎉 tail\n"

    bytes = Commonmarker.to_html(md, options: {render: {sourcepos: true}})
    chars = Commonmarker.to_html(md,
      options: {parse: {sourcepos_chars: true}, render: {sourcepos: true}})

    assert_includes bytes, %(<strong data-sourcepos="1:11-1:20">)
    assert_includes chars, %(<strong data-sourcepos="1:5-1:10">)
  end

  def test_char_columns_count_codepoints_not_grapheme_clusters
    # Ruby's String#[] indexes codepoints too, so slicing stays correct even
    # where a grapheme cluster spans several of them.
    {
      "👨‍👩‍👧‍👦 family" => [14, 8],
      "🇲🇽 flag" => [7, 6],
      "e\u0301 combining" => [12, 11] # "e" + U+0301
    }.each do |line, (codepoints, graphemes)|
      assert_equal codepoints, line.length, line.inspect
      assert_equal graphemes, line.grapheme_clusters.length, line.inspect

      column = end_column(paragraph_position(line, chars: true))

      assert_equal codepoints, column, line.inspect
      assert_equal line, line[0, column], line.inspect
    end
  end

  def test_char_columns_do_not_change_line_numbers
    md = "para\n\n> 日本語のテキスト 🎉\n> もう一行\n"

    bytes = Commonmarker.to_html(md, options: RENDER)
    chars = Commonmarker.to_html(md,
      options: {parse: {sourcepos_chars: true}, render: RENDER[:render]})

    assert_includes bytes, %(<blockquote data-sourcepos="3:1-4:14">)
    assert_includes chars, %(<blockquote data-sourcepos="3:1-4:6">)
  end

  # --- Surprises worth pinning ----------------------------------------------

  def test_to_html_syntax_highlights_by_default_and_tags_pre_not_code
    highlighted = Commonmarker.to_html("```ruby\nputs 1\n", options: RENDER)
    plain = Commonmarker.to_html("```ruby\nputs 1\n", options: RENDER, plugins: NO_HIGHLIGHT)

    assert_includes highlighted, "background-color:#2b303b"
    refute_includes plain, "background-color"

    # github_pre_lang defaults to true: the language lands as lang= on <pre>,
    # not as class="language-ruby" on <code>.
    pre = Nokogiri::HTML5.fragment(plain).at_css("pre")

    assert_equal "ruby", pre["lang"]
    assert_equal "1:1-2:6", pre["data-sourcepos"]
    refute_includes plain, "language-ruby"

    # Either way the attribute is on <pre>, which is the element a top-level
    # walk sees.
    assert_match(/<pre[^>]*data-sourcepos=/, highlighted)
  end

  def test_indented_code_block_end_column_is_zero
    html = Commonmarker.to_html("para\n\n    indented code\n\ntail\n", options: RENDER,
      plugins: NO_HIGHLIGHT)

    # The range starts past the indent and ends at column 0 of the FOLLOWING
    # line. A slicer must read column 0 as "end of the previous line", never as
    # an index. (Drop the trailing blank line and the same block reports
    # 3:5-3:17 instead, so the shape is context-dependent.)
    assert_includes html, %(data-sourcepos="3:5-4:0")
  end

  def test_list_item_end_positions_can_run_past_the_list_end
    fragment = Nokogiri::HTML5.fragment(
      Commonmarker.to_html("- a\n- b\n\n1. x\n2. y\n", options: RENDER)
    )

    assert_equal "1:1-2:3", fragment.at_css("ul")["data-sourcepos"]
    # The last <li> claims line 3 column 0 -- one line beyond the <ul> that
    # contains it, and onto the blank separator line. Nested positions are not
    # guaranteed to nest. It only happens when a bullet list is followed
    # directly by an ordered list; "- a\n- b\n\ntail\n" reports 2:1-2:3.
    assert_equal "2:1-3:0", fragment.at_css("ul").css("li").last["data-sourcepos"]
  end

  private

  def code_block_position(markdown)
    Commonmarker.parse(markdown).first.source_position
  end

  def paragraph_position(line, chars:)
    options = {parse: {sourcepos_chars: chars}, render: {sourcepos: true}}
    Commonmarker.to_html("#{line}\n", options:)[/data-sourcepos="([^"]+)"/, 1]
  end

  # Slices one line by a "L:C-L:C" range, 1-based inclusive, the way a
  # character-oriented splitter would.
  def slice_by_columns(line, range)
    from, to = range.split("-").map { it.split(":").last.to_i }
    line[from - 1, to - from + 1]
  end

  def end_column(range)
    range.split("-").last.split(":").last.to_i
  end

  def top_level_positions(markdown)
    html = Commonmarker.to_html(markdown, options: RENDER.merge(extension: EXTENSIONS),
      plugins: NO_HIGHLIGHT)

    Nokogiri::HTML5.fragment(html).children.filter_map do |el|
      [el.name, el["data-sourcepos"]] if el.element?
    end
  end

  EXTENSIONS = {
    table: true, strikethrough: true, tasklist: true, autolink: true,
    footnotes: true, tagfilter: false
  }.freeze

  # Line numbers in test_every_top_level_block_except_html_carries_data_sourcepos
  # refer to this document. Editing it means re-deriving them.
  def kitchen_sink
    <<~MD
      # heading

      paragraph text

      > a quote
      > second line

      - item one
      - item two

      1. first
      2. second

      | a | b |
      |---|---|
      | 1 | 2 |

      ```ruby
      puts 1
      ```

          indented code

      ---

      <div class="raw">
      html block
      </div>

      - [ ] task
      - [x] done

      ~~strike~~ and a [ref][r]

      [r]: https://example.com

      Term
      : definition?

      footnote ref[^1]

      [^1]: the note
    MD
  end
end
