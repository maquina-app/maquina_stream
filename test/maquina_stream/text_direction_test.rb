# frozen_string_literal: true

require "test_helper"

# Direction is decided per block, by the first strong character, exactly as the
# bidi algorithm decides it. A message is one document but not one language: the
# agent that answers in Arabic still names an English identifier, and the block
# is the unit small enough to be right about both.
class TextDirectionTest < ActiveSupport::TestCase
  test "the first strong character decides, and only letters are strong" do
    assert_equal :rtl, MaquinaStream::TextDirection.of("مرحبا بالعالم")
    assert_equal :rtl, MaquinaStream::TextDirection.of("שלום world")
    assert_equal :ltr, MaquinaStream::TextDirection.of("Hello عالم")

    assert_equal :ltr, MaquinaStream::TextDirection.of("١٢٣ Ruby"),
      "Arabic-Indic digits are not strong; the sentence reads left to right"
    assert_nil MaquinaStream::TextDirection.of("42 — !"),
      "nothing strong either way, so nothing to say"
  end

  test "a right-to-left paragraph is marked and a left-to-right one is not" do
    document = render("مرحبا بالعالم\n\nHello world\n")
    paragraphs = document.css("p")

    assert_equal "rtl", paragraphs.first["dir"]
    assert_nil paragraphs.last["dir"],
      "left to right is the default; saying so costs bytes on every block of every frame"
  end

  test "direction is per block, not per document" do
    document = render("Hello world\n\n> ציטוט בעברית\n\nBack to English\n")

    assert_nil document.at_css("p")["dir"]
    assert_equal "rtl", document.at_css("blockquote")["dir"]
    assert_nil document.css("p").last["dir"]
  end

  test "list items and table cells answer for their own text" do
    document = render("- Hello\n- مرحبا\n")
    items = document.css("li")

    assert_nil items.first["dir"]
    assert_equal "rtl", items.last["dir"]
    assert_nil document.at_css("ul")["dir"], "a container takes its direction from its items"

    document = render("| a | b |\n|---|---|\n| Hello | مرحبا |\n")
    cells = document.css("td")

    assert_nil cells.first["dir"]
    assert_equal "rtl", cells.last["dir"]
  end

  # An override inside a comment reorders how code READS without changing what
  # it MEANS. Every character in a fence was written by a model repeating text
  # from somewhere else, so the block is pinned rather than trusted.
  test "a fence carrying bidi controls is pinned left to right" do
    MaquinaStream.register_fence "ruby", strategy: :server

    document = render("```ruby\n# ‮ evil\nputs 1\n```")

    assert_equal "ltr", document.at_css("[data-ms-code]")["dir"]
  end

  test "an ordinary fence is not pinned, and the source is never rewritten" do
    MaquinaStream.register_fence "ruby", strategy: :server

    document = render("```ruby\nputs 1\n```")

    assert_nil document.at_css("[data-ms-code]")["dir"]

    document = render("```ruby\n# ‮ evil\nputs 1\n```")

    assert_includes document.at_css("[data-ms-code-source]").text, "‮",
      "the copy button hands back what the model wrote; altering it silently is worse"
  end

  test "a passthrough fence is pinned too" do
    MaquinaStream.register_fence "plain", strategy: :passthrough

    document = render("```plain\n‮ evil\n```")

    assert_equal "ltr", document.at_css("pre")["dir"]
  end

  test "direction survives the sanitizer" do
    document = render("مرحبا بالعالم\n")

    assert_equal "rtl", document.at_css("p")["dir"]
  end

  private
    def render(markdown)
      Nokogiri::HTML5.fragment(MaquinaStream::Renderer.call(markdown))
    end
end
