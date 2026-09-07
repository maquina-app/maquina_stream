# frozen_string_literal: true

require "test_helper"

# Properties of the pipeline as a whole, asserted over the corpus rather than
# over one hand-picked document.
class PipelinePropertiesTest < ActiveSupport::TestCase
  CORPUS = Dir[File.expand_path("../fixtures/markdown/*.md", __dir__)] +
    Dir[File.expand_path("../fixtures/retroactive/*.md", __dir__)]

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
    def strip_reveal(html)
      html.gsub(' data-ms-reveal=""', "").gsub(' data-ms-caret=""', "")
    end

    def measure
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
    end
end
