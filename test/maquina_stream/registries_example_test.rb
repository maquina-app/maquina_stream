# frozen_string_literal: true

require "test_helper"

# The dummy app's registrations are the documented example a host copies, so
# they are exercised as a host would use them: markdown in, rendered HTML out.
# A registry example that is only asserted at the registry level proves nothing
# about whether the pipeline honours it.
class RegistriesExampleTest < ActiveSupport::TestCase
  test "the dummy app registers one language of each fence strategy" do
    strategies = %w[ruby text mermaid].to_h { |info| [info, MaquinaStream.fences[info].options[:strategy]] }

    assert_equal({"ruby" => :server, "text" => :passthrough, "mermaid" => :client}, strategies)
  end

  test "a server fence highlights through the code_block component" do
    document = render("```ruby\nputs 1\n```")

    assert_equal "ruby", document.at_css("[data-ms-code]")["data-ms-code-lang"]
    refute_empty document.css("[data-ms-code] code span")
  end

  test "a passthrough fence is untouched" do
    document = render("```text\ntal cual\n```")

    assert_nil document.at_css("[data-ms-code]")
    assert_includes document.text, "tal cual"
  end

  test "a client fence defers to its controller once closed" do
    document = render("```mermaid\ngraph TD; A-->B;\n```")
    node = document.at_css("[data-controller='ms-diagram']")

    assert node
    assert node.at_css("[data-ms-diagram-target='output'][data-turbo-permanent]"),
      "the output element is client state and must be permanent"
    assert_includes JSON.parse(node["data-ms-diagram-payload-value"])["source"], "graph TD"
  end

  test "the source tag renders through its component with only its registered attributes" do
    markdown = %(Según la fuente <source id="3" href="https://example.com/a" title="Un artículo" onclick="alert(1)"></source>.)
    document = render(markdown)

    citation = document.at_css("[data-component='source-citation']")

    assert citation, "the registered tag must render through its partial"
    assert_includes citation.text, "Un artículo"
    assert_nil citation["onclick"], "an attribute the registration does not list must never reach the partial"
    assert_includes document.to_html, "https://example.com/a"
  end

  test "an unregistered tag does not survive" do
    document = render(%(texto <danger id="1">contenido</danger> más texto))

    assert_nil document.at_css("danger")
    assert_includes document.text, "más texto"
  end

  private
    def render(markdown)
      Nokogiri::HTML5.fragment(MaquinaStream::Renderer.call(markdown))
    end
end
