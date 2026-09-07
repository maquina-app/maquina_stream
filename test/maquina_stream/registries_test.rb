# frozen_string_literal: true

require "test_helper"

class MaquinaStream::RegistriesTest < ActiveSupport::TestCase
  test "register_element stores the registration" do
    MaquinaStream.register_element :h2, partial: "my/headings/h2"

    assert_equal "my/headings/h2", MaquinaStream.elements[:h2].options[:partial]
  end

  test "register_tag stores the registration" do
    MaquinaStream.register_tag :source,
      attributes: %w[id],
      partial: "my/tags/source",
      literal_content: false

    tag = MaquinaStream.tags[:source]

    assert_equal %w[id], tag.options[:attributes]
    assert_equal "my/tags/source", tag.options[:partial]
    assert_equal false, tag.options[:literal_content]
  end

  test "register_fence stores every strategy, keyed by info string" do
    payload = ->(source, info) { { source: source, info: info } }

    MaquinaStream.register_fence "ruby", strategy: :server
    MaquinaStream.register_fence "unknown", strategy: :passthrough
    MaquinaStream.register_fence "mermaid", strategy: :client, controller: "ms-diagram", payload: payload

    assert_equal :server, MaquinaStream.fences["ruby"].options[:strategy]
    assert_equal :passthrough, MaquinaStream.fences["unknown"].options[:strategy]

    mermaid = MaquinaStream.fences["mermaid"]

    assert_equal :client, mermaid.options[:strategy]
    assert_equal "ms-diagram", mermaid.options[:controller]
    assert_equal({ source: "graph TD", info: "mermaid" }, mermaid.options[:payload].call("graph TD", "mermaid"))
  end

  test "re-registering replaces the previous registration" do
    MaquinaStream.register_fence "ruby", strategy: :server
    MaquinaStream.register_fence "ruby", strategy: :passthrough

    assert_equal 1, MaquinaStream.fences.size
    assert_equal :passthrough, MaquinaStream.fences["ruby"].options[:strategy]
  end
end
