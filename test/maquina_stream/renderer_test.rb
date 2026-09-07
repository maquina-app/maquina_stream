# frozen_string_literal: true

require "test_helper"

# The renderer is judged on structure, not on the exact markup a component
# happens to emit today. Golden files cover the markup; these cover the contract.
class RendererTest < ActiveSupport::TestCase
  setup do
    MaquinaStream.reset_registries!
    MaquinaStream.register_fence "ruby", strategy: :server
    MaquinaStream.register_fence "text", strategy: :passthrough
    MaquinaStream.register_fence "mermaid",
      strategy: :client,
      controller: "ms-diagram",
      payload: ->(source, info) { {source: source, info: info} }
  end

  teardown do
    MaquinaStream.reset_registries!
    MaquinaStream.reset_configuration!
  end

  test "renders markdown to sanitized html" do
    html = MaquinaStream::Renderer.call("# Title\n\nA paragraph with **bold**.")

    assert_includes html, "<h1"
    assert_includes html, "Title"
    assert_includes html, "<strong>bold</strong>"
  end

  test "runs outside a rails request with no stubbing" do
    # No controller, no request, no view context borrowed from anywhere. If this
    # ever needs a stub, the design has gone wrong rather than the test.
    assert_nil defined?(@request)

    assert_includes MaquinaStream::Renderer.call("plain"), "plain"
  end

  test "empty input renders empty output" do
    assert_equal "", MaquinaStream::Renderer.call("")
    assert_equal "", MaquinaStream::Renderer.call(nil)
  end

  test "repairs the streaming tail before parsing" do
    html = MaquinaStream::Renderer.call("a **half-finished bold")

    assert_includes html, "<strong>"
  end

  test "closed server fence is highlighted and carries its raw source" do
    html = MaquinaStream::Renderer.call("```ruby\nputs 1\n```")
    document = Nokogiri::HTML5.fragment(html)

    assert document.at_css("[data-ms-code]"), "code block did not render through the component"
    assert_equal "ruby", document.at_css("[data-ms-code]")["data-ms-code-lang"]
    carrier = document.at_css("[data-ms-code-source]")

    assert carrier, "raw source must ship with the block for copy and download"
    assert carrier["hidden"], "the carrier must stay hidden or every code block renders twice"
    assert_equal "puts 1\n", carrier.text

    highlighted = document.at_css("[data-ms-code] pre:not([data-ms-code-source]) code")

    refute_empty highlighted.css("span"),
      "highlighted markup must reach the DOM as elements, not as escaped text"
  end

  test "open server fence performs no highlighting at all" do
    html = MaquinaStream::Renderer.call("```ruby\nputs 1")
    document = Nokogiri::HTML5.fragment(html)

    code = document.at_css("[data-ms-code] code")

    assert code, "an open fence still renders a code shell"
    assert_empty code.css("span"), "an open fence must not be highlighted: the work is thrown away next frame"
  end

  test "passthrough fence is left alone" do
    html = MaquinaStream::Renderer.call("```text\nno tocar\n```")

    assert_includes html, "no tocar"
    refute Nokogiri::HTML5.fragment(html).at_css("[data-ms-code]"),
      "a passthrough fence must not be dressed up as a code component"
  end

  test "client fence emits no payload until it closes" do
    open_html = MaquinaStream::Renderer.call("```mermaid\ngraph TD")
    closed_html = MaquinaStream::Renderer.call("```mermaid\ngraph TD\n```")

    refute_includes open_html, "payload-value",
      "an open client fence must not hand the client half a diagram"
    assert_includes closed_html, "data-ms-diagram-payload-value"
    assert_includes closed_html, "graph TD"
  end

  test "client fence payload survives quotes and angle brackets" do
    hostile = %(```mermaid\nA["</div><script>alert(1)</script>"]\n```)
    html = MaquinaStream::Renderer.call(hostile)
    document = Nokogiri::HTML5.fragment(html)
    payload = document.at_css("[data-ms-diagram-payload-value]")["data-ms-diagram-payload-value"]

    refute_includes html, "<script>", "the payload broke out of its attribute"
    assert_includes JSON.parse(payload)["source"], "alert(1)", "the payload must still carry the literal source"
  end

  test "tables are wrapped so they can scroll and be copied" do
    html = MaquinaStream::Renderer.call("| a | b |\n|---|---|\n| 1 | 2 |")
    document = Nokogiri::HTML5.fragment(html)

    assert document.at_css("[data-ms-table] table"), "a table must be wrapped"
  end

  test "elements carry their styling hook" do
    document = Nokogiri::HTML5.fragment(MaquinaStream::Renderer.call("## two\n\ntext"))

    assert_equal "h2", document.at_css("h2")["data-ms-element"]
    assert_equal "p", document.at_css("p")["data-ms-element"]
  end

  test "source positions do not leak into rendered output" do
    refute_includes MaquinaStream::Renderer.call("# title"), "data-sourcepos"
  end

  test "streaming and static differ only in reveal attributes" do
    markdown = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))

    streaming = MaquinaStream::Renderer.call(markdown, mode: :streaming)
    static = MaquinaStream::Renderer.call(markdown, mode: :static)

    # Identical, not "identical apart from animation attributes": blocks carry
    # no chrome at all, so live, reload, replay and export are one document.
    assert_equal streaming, static
  end

  test "rejects an unknown mode rather than guessing" do
    assert_raises(ArgumentError) { MaquinaStream::Renderer.call("x", mode: :fast) }
  end

  private
    def strip_reveal(html)
      html.gsub(' data-ms-reveal=""', "").gsub(' data-ms-caret=""', "")
    end
end
