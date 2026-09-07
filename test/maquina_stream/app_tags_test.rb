# frozen_string_literal: true

require "test_helper"

# Tags a model gives application meaning to: <thinking>, <answer>, <tool_call>,
# <citation>. CommonMark has never heard of any of them — the line that opens
# one starts an HTML block — so what happens to the text underneath is decided
# by the sanitizer and the splitter, not by the markdown parser.
#
# See docs/registries.md, "App-meaning tags", for the summary this file backs.
class AppTagsTest < ActiveSupport::TestCase
  # The tag opens in block 2 and closes in block 6: the shape the seal lag
  # exists for, if closing it rewrites anything above.
  SPANNING = <<~MARKDOWN
    Intro paragraph.

    Second paragraph before the tag.

    <thinking>
    Alpha reasoning line.

    Beta reasoning line.

    Gamma reasoning line.

    Delta reasoning line.
    </thinking>

    Here is the answer.

    And a closing paragraph.
  MARKDOWN

  setup { MaquinaStream.reset_registries! }

  teardown { MaquinaStream.reset_registries! }

  test "an unregistered tag is dropped and its content is not" do
    blocks = MaquinaStream::Document.new(SPANNING, sid: "m1").blocks
    html = blocks.map(&:html).join("\n")

    assert_nil Nokogiri::HTML5.fragment(html).at_css("thinking"),
      "an unregistered tag must not survive as markup"

    %w[Alpha Beta Gamma Delta].each do |line|
      assert(blocks.any? { |block| block.html.include?("#{line} reasoning line.") },
        "#{line} reasoning line was lost between the sanitizer and the blocks")
    end
  end

  # maquina_remend's html_tags handler only removes a tag whose ">" has not
  # arrived yet — "text <thinki" becomes "text". It does not balance an element
  # that opened and has not closed, and it does not have to: the sanitizer
  # unwraps the tag whether it closed or not, so the content is unwrapped text
  # on every frame either way.
  test "content survives every frame while the tag is still open" do
    open_tag = SPANNING[0, SPANNING.index("</thinking>")]

    (0..open_tag.length).step(5).each do |cut|
      blocks = MaquinaStream::Document.new(open_tag[0, cut].to_s, sid: "m1").blocks
      text = blocks.map { |block| Nokogiri::HTML5.fragment(block.html).text }.join(" ")

      %w[Alpha Beta Gamma Delta].each do |line|
        complete = "#{line} reasoning line."
        next unless open_tag[0, cut].to_s.include?(complete)

        assert_includes text, complete,
          "#{complete} had arrived in full but no block carried it at truncation point #{cut}"
      end
    end
  end

  # No flicker: a line that has arrived in full never leaves the document again,
  # least of all on the frame that closes the tag.
  test "a line that has arrived never disappears on a later frame" do
    seen = []

    (0..SPANNING.length).each do |cut|
      text = MaquinaStream::Document.new(SPANNING[0, cut], sid: "m1")
        .blocks
        .map { |block| Nokogiri::HTML5.fragment(block.html).text }
        .join(" ")

      seen.each do |line|
        assert_includes text, line, "#{line.inspect} vanished at truncation point #{cut}"
      end

      %w[Alpha Beta Gamma Delta].each do |name|
        line = "#{name} reasoning line."
        seen << line if text.include?(line) && !seen.include?(line)
      end
    end
  end

  # The retroactive-change case the seal lag exists for, tested against the seal
  # pointer rather than argued about. An unregistered tag closing does not
  # rewrite the blocks above it, because the sanitizer unwrapped it on every
  # earlier frame too — the block boundaries never depended on the tag.
  test "closing an unregistered tag never rewrites a sealed block" do
    assert_empty seal_violations(SPANNING)
  end

  # A registered tag whose content is several blocks. The registry works on ONE
  # node: the post-pass replaces the tag node with the partial and hands it the
  # node's inner HTML.
  #
  # Two things follow, and both are visible here rather than argued:
  #
  # 1. Everything inside the tag becomes ONE block. There is no way for the
  #    partial to receive four paragraphs and leave four blocks behind.
  # 2. CommonMark emits the closing tag inside a paragraph — "</thinking></p>" —
  #    so the HTML5 parser never closes the element, and the rest of the message
  #    is parsed INSIDE it. The partial receives content that came after the
  #    closing tag.
  #
  # The registry is an inline/single-node facility. This is the failing case,
  # asserted so it fails loudly if it is ever fixed rather than sitting in a
  # document nobody reads.
  test "a registered block-level tag takes the rest of the message with it" do
    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"

    blocks = MaquinaStream::Document.new(SPANNING, sid: "m1").blocks
    reasoning = blocks.find { |block| block.html.include?("data-ms-reasoning") }

    assert reasoning, "the registered tag must render through its partial"

    assert_includes reasoning.html, "Alpha reasoning line.",
      "the whole tag body is one block"
    assert_includes reasoning.html, "And a closing paragraph.",
      "KNOWN LIMITATION: content after </thinking> is parsed inside the tag and " \
      "reaches the partial. register_tag is single-node; see docs/registries.md."
    assert_equal blocks.last, reasoning,
      "everything after the tag opens ends up in the same block"
  end

  # And the consequence for streaming, which is the part that costs something:
  # that block is the tail, so it is never far enough from the end to seal. The
  # rest of the message is re-sent on every frame.
  test "a registered block-level tag leaves the rest of the message unsealable" do
    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"

    # Document renders lazily, so each one is forced while the registry it is
    # being measured under is the one that is installed.
    registered = MaquinaStream::Document.new(SPANNING, sid: "m1")
    registered.blocks
    MaquinaStream.reset_registries!
    unregistered = MaquinaStream::Document.new(SPANNING, sid: "m1")
    unregistered.blocks

    assert_equal 3, registered.blocks.length,
      "the tag body plus everything after it collapses into one block"
    assert_equal 8, unregistered.blocks.length

    assert_operator registered.seal_pointer, :<, unregistered.seal_pointer,
      "the merged tail can never seal, so far more of the message is re-sent per frame"

    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"

    assert_empty seal_violations(SPANNING),
      "the merge only ever grows the tail, so it does not rewrite a sealed block"
  end

  private
    # Replays the buffer character by character and reports every sealed block
    # whose HTML changed after it was sealed — the failure sealing exists to
    # prevent, since a sealed block is never broadcast again.
    def seal_violations(markdown)
      frozen = {}

      (0..markdown.length).each_with_object([]) do |cut, violations|
        MaquinaStream::Document.new(markdown[0, cut], sid: "m1").sealed_blocks.each do |block|
          if frozen.key?(block.id)
            violations << "#{block.id} changed after sealing, at truncation point #{cut}" unless frozen[block.id] == block.html
          else
            frozen[block.id] = block.html
          end
        end
      end
    end
end
