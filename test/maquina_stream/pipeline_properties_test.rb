# frozen_string_literal: true

require "test_helper"

# Properties of the pipeline as a whole, asserted over the corpus rather than
# over one hand-picked document.
class PipelinePropertiesTest < ActiveSupport::TestCase
  CORPUS = Dir[File.expand_path("../fixtures/markdown/*.md", __dir__)] +
    Dir[File.expand_path("../fixtures/retroactive/*.md", __dir__)]

  # Tags a model gives application meaning to. None of them is registered, so
  # none may survive as markup — and every character between them must still
  # land in exactly one block.
  APP_TAG_CASES = [
    ["thinking block", "<thinking>\nFirst I consider the problem.\n\nThen I consider the alternative.\n</thinking>\n\nHere is the answer.\n"],
    ["unterminated thinking block", "<thinking>\nReasoning that never closes.\n\nStill reasoning.\n"],
    ["inline citation", "The model wrote <citation>source 3</citation> mid-sentence.\n"],
    ["tag around a list", "<answer>\n- one\n- two\n</answer>\n"],
    ["tag between paragraphs", "Intro paragraph.\n\n<tool_call>\n{\"q\": 1}\n</tool_call>\n\nOutro paragraph.\n"]
  ].freeze

  setup do
    MaquinaStream.reset_registries!
    MaquinaStream.register_fence "ruby", strategy: :server
    MaquinaStream.register_fence "mermaid", strategy: :client, controller: "ms-diagram"
  end

  teardown { MaquinaStream.reset_registries! }

  test "live and static modes differ only in reveal attributes, across the whole corpus" do
    refute_empty CORPUS

    CORPUS.each do |path|
      markdown = File.read(path)
      streaming = MaquinaStream::Renderer.call(markdown, mode: :streaming).to_s
      static = MaquinaStream::Renderer.call(markdown, mode: :static).to_s

      assert_equal strip_reveal(streaming), strip_reveal(static),
        "#{File.basename(path)} renders differently in streaming and static mode"
    end
  end

  test "no inline colour anywhere in rendered output" do
    # Themes are two stylesheets, switched by the document. A single inline
    # colour would mean dark mode could not switch without a re-render.
    CORPUS.each do |path|
      html = MaquinaStream::Renderer.call(File.read(path)).to_s

      refute_match(/style\s*=/, html, "#{File.basename(path)} emitted an inline style")
      refute_match(/#[0-9a-fA-F]{6}\b/, html, "#{File.basename(path)} emitted a literal colour")
    end
  end

  test "output is stable: rendering the same buffer twice gives the same html" do
    CORPUS.each do |path|
      markdown = File.read(path)

      assert_equal MaquinaStream::Renderer.call(markdown).to_s,
        MaquinaStream::Renderer.call(markdown).to_s,
        "#{File.basename(path)} does not render deterministically"
    end
  end

  # The property that would have caught the app-tag bug: <thinking> is an HTML
  # block to CommonMark, the sanitizer unwraps the unknown element and keeps its
  # children, and the text under it was then a bare text node at the top level of
  # the fragment — which `children.select(&:element?)` dropped without a word.
  #
  # Asserted as a property rather than as that one case, because the same loss
  # applies to anything the unwrap can strand there.
  test "splitting into blocks loses no content, across the whole corpus" do
    refute_empty CORPUS

    cases = CORPUS.map { |path| [File.basename(path), File.read(path)] } + APP_TAG_CASES

    cases.each do |name, markdown|
      document = MaquinaStream::Document.new(markdown, sid: "m1")

      assert_equal text_of(document.html), joined_text_of(document.blocks),
        "#{name}: content survived sanitizing but no block carries it"
    end
  end

  # The same property held frame by frame. A block that only loses content while
  # the tag is still open is a block that flickers, and a flicker that repairs
  # itself on the last frame is invisible to a test that only renders the whole
  # buffer.
  test "splitting loses no content at any point in the stream" do
    APP_TAG_CASES.each do |name, markdown|
      (0..markdown.length).step(7).each do |cut|
        document = MaquinaStream::Document.new(markdown[0, cut].to_s, sid: "m1")

        assert_equal text_of(document.html), joined_text_of(document.blocks),
          "#{name}: content lost by the split at truncation point #{cut}"
      end
    end
  end

  test "a 500 line fence renders within the frame budget once closed" do
    source = (1..500).map { |n| "  line_#{n} = compute(#{n})" }.join("\n")
    closed = "```ruby\n#{source}\n```"

    MaquinaStream::Renderer.call(closed) # warm up
    elapsed = measure { MaquinaStream::Renderer.call(closed) }

    assert_operator elapsed, :<, MaquinaStream.config.frame_budget_ms,
      "a closed 500-line fence took #{elapsed.round(1)}ms, over the #{MaquinaStream.config.frame_budget_ms}ms frame budget"
  end

  test "an open 500 line fence is cheaper than a closed one, because it is not highlighted" do
    source = (1..500).map { |n| "  line_#{n} = compute(#{n})" }.join("\n")
    open_fence = "```ruby\n#{source}"
    closed = "```ruby\n#{source}\n```"

    MaquinaStream::Renderer.call(open_fence)
    MaquinaStream::Renderer.call(closed)

    open_ms = measure { MaquinaStream::Renderer.call(open_fence) }
    closed_ms = measure { MaquinaStream::Renderer.call(closed) }

    assert_operator open_ms, :<, closed_ms,
      "an open fence must skip highlighting entirely: open #{open_ms.round(1)}ms vs closed #{closed_ms.round(1)}ms"

    document = Nokogiri::HTML5.fragment(MaquinaStream::Renderer.call(open_fence))

    assert_empty document.css("[data-ms-code] code span")
  end

  private
    # Text, not markup: whitespace between blocks is layout, and the split is
    # allowed to move it. Everything else has to be there.
    def text_of(html)
      normalize(Nokogiri::HTML5.fragment(html.to_s).text)
    end

    # The blocks' text is joined AFTER each one is extracted. Joining their HTML
    # and parsing once would hide exactly the bug this asserts against, and
    # re-parsing extracted text would swallow any literal "<tag>" a model wrote.
    def joined_text_of(blocks)
      normalize(blocks.map { |block| Nokogiri::HTML5.fragment(block.html).text }.join(" "))
    end

    def normalize(text)
      text.gsub(/\s+/, " ").strip
    end

    def strip_reveal(html)
      html.gsub(' data-ms-reveal=""', "").gsub(' data-ms-caret=""', "")
    end

    def measure
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
    end
end
