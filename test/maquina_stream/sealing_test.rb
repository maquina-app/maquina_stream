# frozen_string_literal: true

require "test_helper"

# The seal invariant, asserted rather than eyeballed.
#
# A block is sealed when config.seal_lag later blocks exist. Once sealed its
# HTML is frozen and never re-broadcast, so if a later frame changes it the
# browser is never told — the message is quietly wrong until a repair. That is
# the failure this file exists to catch.
class SealingTest < ActiveSupport::TestCase
  RETROACTIVE = Dir[File.expand_path("../fixtures/retroactive/*.md", __dir__)].sort

  test "a sealed block's html never changes again, replayed character by character" do
    refute_empty RETROACTIVE

    RETROACTIVE.each do |path|
      document = File.read(path)
      frozen = {}

      (0..document.length).each do |cut|
        MaquinaStream::Document.new(document[0, cut], sid: "m1").sealed_blocks.each do |block|
          if frozen.key?(block.id)
            assert_equal frozen[block.id], block.html, <<~MESSAGE
              #{File.basename(path)}: #{block.id} changed after it was sealed, at truncation point #{cut}.

              The seal lag of #{MaquinaStream.config.seal_lag} was not enough for this document.
              #{File.read(path).lines.first}
            MESSAGE
          else
            frozen[block.id] = block.html
          end
        end
      end
    end
  end

  # The case that broke the original seal-lag design. A link reference
  # definition resolves links arbitrarily far above it, so no fixed lag can make
  # the block safe - the pointer has to stop at it instead.
  test "a block with an unresolved reference never seals, however many blocks follow" do
    unresolved = <<~MD
      See the [documentation][docs] for more detail.

      One.

      Two.

      Three.

      Four.
    MD

    document = MaquinaStream::Document.new(unresolved, sid: "m1")

    assert_empty document.sealed_blocks, "a block whose link is still unresolved must not freeze"

    resolved = "#{unresolved}\n[docs]: https://example.com/docs\n"

    refute_empty MaquinaStream::Document.new(resolved, sid: "m1").sealed_blocks,
      "once the definition arrives the pointer must move again"
  end

  test "a half-arrived definition does not count as resolved" do
    partial = "See [docs][docs].\n\nOne.\n\nTwo.\n\n[docs]:"

    assert_empty MaquinaStream::Document.new(partial, sid: "m1").sealed_blocks

    truncated_url = "See [docs][docs].\n\nOne.\n\nTwo.\n\n[docs]: https://exa"

    assert_empty MaquinaStream::Document.new(truncated_url, sid: "m1").sealed_blocks,
      "a truncated destination still resolves to the wrong host when it completes"
  end

  test "a sealed block's html never changes in a long document either" do
    markdown = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))
    frozen = {}

    (0..markdown.length).step(3) do |cut|
      MaquinaStream::Document.new(markdown[0, cut], sid: "m1").sealed_blocks.each do |block|
        if frozen.key?(block.id)
          assert_equal frozen[block.id], block.html, "#{block.id} changed after sealing, at truncation point #{cut}"
        else
          frozen[block.id] = block.html
        end
      end
    end

    refute_empty frozen
  end

  test "the seal pointer trails the tail by exactly seal_lag" do
    document = MaquinaStream::Document.new(File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__)))

    assert_equal document.blocks.length - MaquinaStream.config.seal_lag, document.sealed_blocks.length
    assert_equal MaquinaStream.config.seal_lag, document.unsealed_blocks.length
  end

  test "seal lag is host configurable" do
    markdown = "# one\n\ntwo\n\nthree\n\nfour\n\nfive"

    MaquinaStream.configure { |c| c.seal_lag = 4 }
    document = MaquinaStream::Document.new(markdown)

    assert_equal document.blocks.length - 4, document.sealed_blocks.length
  end

  test "nothing is sealed while the document is shorter than the lag" do
    document = MaquinaStream::Document.new("just one paragraph")

    assert_empty document.sealed_blocks
    assert_equal 1, document.blocks.length
  end

  test "block ids are index derived, never content derived" do
    first = MaquinaStream::Document.new("# one\n\ntwo", sid: "m1").blocks
    second = MaquinaStream::Document.new("# one changed\n\ntwo", sid: "m1").blocks

    assert_equal first.map(&:id), second.map(&:id),
      "an id that moves when the content changes makes morph delete and recreate the node"
    refute_equal first.first.digest, second.first.digest, "the digest is what notices a change"
  end

  test "a stream cancelled mid-block still seals into valid html" do
    cancelled = "# Title\n\nA complete paragraph.\n\nAnother paragraph that cuts off mid"
    document = MaquinaStream::Document.new(cancelled, sid: "m1")

    assert_operator document.blocks.length, :>=, 3
    document.blocks.each do |block|
      fragment = Nokogiri::HTML5.fragment(block.html)

      assert_predicate fragment.errors, :empty?, "block #{block.index} did not parse: #{fragment.errors.first}"
      refute_empty block.html.strip
    end
  end

  test "every block maps back to a slice of the raw buffer" do
    markdown = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))
    document = MaquinaStream::Document.new(markdown, sid: "m1")

    document.blocks.each do |block|
      assert block.line_range, "block #{block.index} has no source range"
      refute_empty block.markdown.strip, "block #{block.index} sliced an empty range from the buffer"
    end
  end
end
