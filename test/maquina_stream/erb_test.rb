# frozen_string_literal: true

require "test_helper"
require "herb"

# HTML-aware checks on the engine's ERB.
#
# The component rules were previously asserted by grepping template source with
# regexes, which cannot tell an attribute from a string that looks like one, and
# cannot see malformed HTML at all. Herb parses the template into an HTML+ERB
# AST, so these are structural.
class ErbTest < ActiveSupport::TestCase
  ENGINE_VIEWS = File.expand_path("../../app/views", __dir__)
  COMPONENTS = Dir[File.join(ENGINE_VIEWS, "maquina_stream/components/_*.html.erb")].sort

  test "every engine template parses as valid html+erb" do
    templates = Dir[File.join(ENGINE_VIEWS, "**/*.html.erb")]

    refute_empty templates

    templates.each do |path|
      result = Herb.parse(File.read(path))

      assert_empty result.errors.map(&:to_s),
        "#{relative(path)} does not parse:\n#{result.errors.join("\n")}"
    end
  end

  test "every component partial declares a data-component attribute in markup" do
    refute_empty COMPONENTS

    COMPONENTS.each do |path|
      source = File.read(path)

      assert_includes source, "component:",
        "#{relative(path)} never names its data-component"
    end
  end

  # The destination name rule, checked against the component's own file name
  # rather than against a hand-kept list.
  test "no component uses an ms- prefixed data-component name" do
    COMPONENTS.each do |path|
      source = File.read(path)

      refute_match(/component:\s*["']ms-/, source,
        "#{relative(path)} uses an engine-prefixed data-component; the destination name is the one that ships")
    end
  end

  test "herb finds no unclosed or mismatched tags in the components" do
    COMPONENTS.each do |path|
      result = Herb.parse(File.read(path))
      messages = result.errors.map(&:to_s)

      assert_empty messages, "#{relative(path)}: #{messages.join(", ")}"
    end
  end

  private
    def relative(path)
      path.sub("#{File.expand_path("../..", __dir__)}/", "")
    end
end
