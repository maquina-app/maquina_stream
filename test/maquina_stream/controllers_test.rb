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

  # The Ruby half of "controls inert while streaming". The JavaScript half is
  # verified in a browser (docs/interaction.md); this pins the marker the guard
  # depends on, because when it went missing nothing failed — the controls
  # simply stayed live through every stream.
  test "every rendered control is marked for the stream guard" do
    document = render("```ruby\nputs 1\n```\n\n| a |\n|---|\n| 1 |")

    actions = document.css("[data-action^='ms-code'], [data-action^='ms-table']")

    refute_empty actions

    actions.each do |control|
      assert control.attribute("data-ms-control"),
        "#{control["data-action"]} is not marked data-ms-control, so it stays clickable mid-stream"
    end
  end

  test "control labels follow the host's locale" do
    document = I18n.with_locale(:en) { render("| a |\n|---|\n| 1 |") }

    assert_includes document.at_css("[data-action='ms-table#copy']")["aria-label"], "Copy"

    document = I18n.with_locale(:es) { render("| a |\n|---|\n| 1 |") }

    assert_includes document.at_css("[data-action='ms-table#copy']")["aria-label"], "Copiar"
  end

  # ------------------------------------------------------------------ ms-reveal
  #
  # The reveal is entirely client-side: it wraps the text that just arrived in
  # one `<span data-ms-revealing>` and unwraps it again on `animationend`. What
  # the server owes it is the marker it binds to and nothing else, and "nothing
  # else" is the half that has to be pinned — chrome the server leaves on a
  # block is drift the digest cannot see (docs/api-surface.md, Phase 7).

  test "every top-level block carries the marker ms-reveal binds to" do
    blocks = document_blocks("Primero.\n\nSegundo.\n\nTercero.\n")

    refute_empty blocks

    blocks.each do |block|
      assert block.attribute("data-ms-block"), "ms-reveal selects [data-ms-block]; this block has no marker"
      refute_empty block["id"].to_s, "the reveal tracks a block across a repair by its id"
    end
  end

  test "the server leaves no reveal chrome on a block" do
    blocks = document_blocks("Primero, con texto suficiente.\n\nSegundo.\n")

    blocks.each do |block|
      assert_empty block.css("[data-ms-revealing]"),
        "the reveal span is the client's, and a server-sent one is drift the manifest diff cannot see"
      assert_nil block["data-ms-reveal"]
      assert_nil block["data-ms-block-state"]
    end
  end

  test "the reveal changes nothing between streaming and static output" do
    markdown = "Un párrafo largo que se revela mientras llega.\n\nY otro.\n"

    assert_equal MaquinaStream::Renderer.call(markdown, mode: :static),
      MaquinaStream::Renderer.call(markdown, mode: :streaming),
      "an animation attribute in the document is an animation attribute in the digest"
  end

  test "ms-reveal is registered under the identifier the DOM contract fixes" do
    index = ENGINE_ROOT.join("app/javascript/maquina_stream/index.js").read

    assert_includes index, "maquina_stream/controllers/ms_reveal_controller"
    assert_includes index, '"ms-reveal": MsRevealController'
  end

  # The suppression seam is two string literals in two files. A rename in either
  # one fails nothing at runtime — the reveal simply never hears the morph
  # coming, and repair starts re-revealing text the reader has already read.
  test "ms-repair and ms-reveal agree on the suppression events" do
    repair = ENGINE_ROOT.join("app/javascript/maquina_stream/controllers/ms_repair_controller.js").read
    reveal = ENGINE_ROOT.join("app/javascript/maquina_stream/controllers/ms_reveal_controller.js").read

    %w[ms:suppress ms:resume].each do |event|
      assert_includes repair, event, "ms-repair no longer dispatches #{event}"
      assert_includes reveal, event, "ms-reveal no longer listens for #{event}"
    end
  end

  test "the reveal stylesheet ships, and honours prefers-reduced-motion" do
    css = ENGINE_ROOT.join("app/assets/stylesheets/maquina_stream/reveal.css")

    assert_predicate css, :exist?

    source = css.read

    assert_includes source, "[data-ms-revealing]"
    assert_includes source, "@media (prefers-reduced-motion: reduce)"
    refute_includes source, "mask-image",
      "a gradient mask placed from a character fraction hides a horizontal band, " \
      "which on a wrapped block crosses lines the reader has already read"
  end

  private
    ENGINE_ROOT = Pathname(File.expand_path("../..", __dir__))

    def render(markdown)
      Nokogiri::HTML5.fragment(MaquinaStream::Renderer.call(markdown))
    end

    # Through Document, not Renderer: the block marker and id are what Document
    # stamps, and they are what the reveal binds to.
    def document_blocks(markdown)
      html = MaquinaStream::Document.new(markdown, config: MaquinaStream.config, sid: "t", mode: :streaming)
        .blocks.map(&:html).join("\n")

      Nokogiri::HTML5.fragment(html).children.select(&:element?)
    end
end
