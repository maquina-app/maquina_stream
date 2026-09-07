# frozen_string_literal: true

require "test_helper"

# The controllers' behaviour is verified in a real browser against
# test/dummy/app/views/harness (see docs/interaction.md). What this file pins is
# the server side of the contract: the markup the renderer emits has to carry
# the actions, targets and carriers the controllers bind to.
#
# Both halves are needed. Every gap found while building this phase was of this
# shape — a controller that worked perfectly with nothing on the page wired to
# it, or markup the sanitizer removed before it ever reached the browser.
class ControllersTest < ActiveSupport::TestCase
  setup { MaquinaStream.register_fence "ruby", strategy: :server }

  test "a code block mounts ms-code and carries its raw source" do
    document = render("```ruby\nputs 1\n```")
    block = document.at_css("[data-ms-code]")

    assert_equal "ms-code", block["data-controller"]
    assert block.at_css("[data-ms-code-source]"), "ms-code reads the carrier, so it has to survive sanitizing"
    assert block.at_css("[data-ms-code-source]")["hidden"]
  end

  test "code block controls are present, typed, and named" do
    document = render("```ruby\nputs 1\n```")

    %w[copy download].each do |action|
      button = document.at_css("[data-action='ms-code##{action}']")

      assert button, "no #{action} control"
      assert_equal "button", button["type"], "a control that submits is a control that navigates away mid-stream"
      refute_empty button["aria-label"].to_s, "#{action} has no accessible name"
    end
  end

  test "a table mounts ms-table with its target and controls" do
    document = render("| a | b |\n|---|---|\n| 1 | 2 |")
    wrapper = document.at_css("[data-ms-table]")

    assert_equal "ms-table", wrapper["data-controller"]
    assert_equal "table", wrapper.at_css("table")["data-ms-table-target"]

    actions = wrapper.css("[data-action^='ms-table']").map { |node| node["data-action"] }

    assert_includes actions, "ms-table#copy"
    assert_includes actions, "ms-table#download"
    assert_includes actions, "ms-table#toggleFullscreen"
  end

  test "table copy controls declare the format they copy" do
    document = render("| a | b |\n|---|---|\n| 1 | 2 |")
    formats = document.css("[data-action='ms-table#copy']").map { |node| node["data-ms-table-format-param"] }

    assert_includes formats, "markdown"
    assert_includes formats, "csv"
  end

  test "controls disappear entirely when the host turns them off" do
    MaquinaStream.configure { |c| c.controls = false }

    document = render("```ruby\nputs 1\n```\n\n| a |\n|---|\n| 1 |")

    assert_empty document.css("[data-action^='ms-code']")
    assert_empty document.css("[data-action^='ms-table']")
    assert_nil document.at_css("[data-ms-table]")["data-controller"],
      "a controller with no controls to drive is dead weight on every frame"
  end

  test "a single control can be turned off on its own" do
    MaquinaStream.configure { |c| c.controls = {code: {copy: true, download: false}} }

    document = render("```ruby\nputs 1\n```")

    assert document.at_css("[data-action='ms-code#copy']")
    assert_nil document.at_css("[data-action='ms-code#download']")
  end

  test "control labels follow the host's locale" do
    document = I18n.with_locale(:en) { render("| a |\n|---|\n| 1 |") }

    assert_includes document.at_css("[data-action='ms-table#copy']")["aria-label"], "Copy"

    document = I18n.with_locale(:es) { render("| a |\n|---|\n| 1 |") }

    assert_includes document.at_css("[data-action='ms-table#copy']")["aria-label"], "Copiar"
  end

  private
    def render(markdown)
      Nokogiri::HTML5.fragment(MaquinaStream::Renderer.call(markdown))
    end
end
