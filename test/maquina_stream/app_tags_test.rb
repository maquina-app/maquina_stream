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

  # A registered tag whose content is several blocks. Renderer::TagBlocks puts
  # blank lines around the tag's own tags before commonmarker sees them, so the
  # element is a well-formed HTML block: it closes where the model closed it,
  # and the partial receives the tag body and nothing else.
  test "a registered block-level tag renders its own content and nothing after it" do
    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"

    blocks = MaquinaStream::Document.new(SPANNING, sid: "m1").blocks
    reasoning = blocks.find { |block| block.html.include?("data-ms-reasoning") }

    assert reasoning, "the registered tag must render through its partial"

    %w[Alpha Beta Gamma Delta].each do |line|
      assert_includes reasoning.html, "#{line} reasoning line.",
        "the whole tag body is one block, so every reasoning line is in it"
    end

    refute_includes reasoning.html, "Here is the answer.",
      "content after </thinking> must never reach the partial"
    refute_includes reasoning.html, "And a closing paragraph.",
      "content after </thinking> must never reach the partial"

    refute_equal blocks.last, reasoning, "the message continues in blocks of its own"
    assert(blocks.any? { |block| block.html.include?("Here is the answer.") && !block.html.include?("data-ms-reasoning") })
    assert(blocks.any? { |block| block.html.include?("And a closing paragraph.") && !block.html.include?("data-ms-reasoning") })
  end

  # The mid-stream case, which is the one that matters: a message is rendered
  # from every prefix of itself, and the leak has to be absent from all of them,
  # not only from the finished document. Replayed character by character.
  test "the partial never receives post-close content at any truncation point" do
    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"

    (0..SPANNING.length).each do |cut|
      source = SPANNING[0, cut]
      after = source.split("</thinking>", 2)[1].to_s
      next if after.strip.empty?

      text = MaquinaStream::Document.new(source, sid: "m1")
        .blocks
        .select { |block| block.html.include?("data-ms-reasoning") }
        .map { |block| Nokogiri::HTML5.fragment(block.html).text }
        .join(" ")

      # Whole lines, and the first characters of a line that is still arriving:
      # a leak of half a sentence is a leak.
      arrived = after.strip[0, 6]
      refute_includes text, arrived,
        "the partial received post-close content (#{arrived.inspect}) at truncation point #{cut}"

      ["Here is the answer.", "And a closing paragraph."].each do |line|
        next unless after.include?(line)

        refute_includes text, line, "the partial received #{line.inspect} at truncation point #{cut}"
      end
    end
  end

  # What the fix costs, measured rather than asserted from memory.
  #
  # The tag body is ONE block — a registered component is one component — so the
  # four reasoning paragraphs that would otherwise be four sealable blocks are a
  # single block that stays open until two blocks follow it. Everything the model
  # writes inside the tag is therefore re-sent on every frame until the tag
  # closes, and the cost grows with the square of the body length.
  #
  # Over this document, replayed character by character: 5 blocks instead of 8,
  # a seal pointer of 3 instead of 6, and 74,063 bytes of unsealed HTML re-sent
  # across the replay instead of 56,767 — 30% more. With a twenty-paragraph
  # reasoning body it is 3.5x, and 88% of it is that one block.
  test "the tag body is one block, and it is re-sent until it closes" do
    # Document renders lazily, so each one is forced while the registry it is
    # being measured under is the one that is installed.
    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"
    registered = MaquinaStream::Document.new(SPANNING, sid: "m1")
    registered.blocks
    registered_bytes = replay_bytes(SPANNING)

    MaquinaStream.reset_registries!
    unregistered = MaquinaStream::Document.new(SPANNING, sid: "m1")
    unregistered.blocks
    unregistered_bytes = replay_bytes(SPANNING)

    assert_equal 5, registered.blocks.length, "the tag body collapses into one block"
    assert_equal 8, unregistered.blocks.length

    assert_operator registered.seal_pointer, :<, unregistered.seal_pointer,
      "one block instead of four means four fewer blocks that can seal"
    assert_operator registered_bytes, :>, unregistered_bytes,
      "the merged body is re-sent on every frame until it closes"

    MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"

    assert_empty seal_violations(SPANNING),
      "the body only ever grows, so closing the tag does not rewrite a sealed block"
  end

  private
    # Every byte of unsealed HTML the replay would put on the wire: the patch
    # set of every frame, summed.
    def replay_bytes(markdown)
      (0..markdown.length).sum do |cut|
        MaquinaStream::Document.new(markdown[0, cut], sid: "m1").unsealed_blocks.sum { |block| block.html.bytesize }
      end
    end

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
