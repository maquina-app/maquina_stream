# frozen_string_literal: true

require "test_helper"

# Golden files, one per feature.
#
# They are compared, never blindly regenerated. `GOLDEN=overwrite bin/test`
# rewrites them, and the diff is then meant to be read: a golden file that is
# regenerated on every red test records whatever the code happens to do, which
# is the opposite of what it is for.
class GoldenTest < ActiveSupport::TestCase
  GOLDEN_DIR = File.expand_path("../fixtures/golden", __dir__)

  CASES = {
    "paragraph_and_inline" => "Un párrafo con **negrita**, *cursiva*, `código` y [enlace](https://example.com).",
    "headings" => "# uno\n\n## dos\n\n### tres",
    "nested_list" => "- primero\n  - anidado con `código`\n- segundo",
    "table" => "| a | b |\n|---|---|\n| 1 | 2 |",
    "blockquote" => "> una cita\n> en dos líneas",
    "code_block_closed" => "```ruby\ndef saludar\n  puts \"hola\"\nend\n```",
    "code_block_open" => "```ruby\ndef saludar\n  puts \"ho",
    "code_block_passthrough" => "```text\nsin resaltado\n```",
    "client_fence_open" => "```mermaid\ngraph TD",
    "client_fence_closed" => "```mermaid\ngraph TD; A-->B;\n```",
    "streaming_tail_repaired" => "un párrafo con **negrita a medias",
    "cjk_and_emoji" => "日本語とEnglishが同じ行に混在する 🎉 con **negrita**"
  }.freeze

  setup do
    MaquinaStream.reset_registries!
    MaquinaStream.register_fence "ruby", strategy: :server
    MaquinaStream.register_fence "text", strategy: :passthrough
    MaquinaStream.register_fence "mermaid",
      strategy: :client,
      controller: "ms-diagram",
      payload: ->(source, info) { {source: source, info: info} }
  end

  teardown { MaquinaStream.reset_registries! }

  CASES.each do |name, markdown|
    test "golden: #{name}" do
      actual = MaquinaStream::Renderer.call(markdown, mode: :static).to_s
      path = File.join(GOLDEN_DIR, "#{name}.html")

      if ENV["GOLDEN"] == "overwrite"
        FileUtils.mkdir_p(GOLDEN_DIR)
        File.write(path, actual)
        skip "golden file rewritten - read the diff before committing it"
      end

      assert File.exist?(path), "missing golden file #{path}. Run GOLDEN=overwrite bin/test and review the result."
      assert_equal File.read(path), actual, <<~MESSAGE
        #{name} no longer renders the way its golden file records.

        If the change is intended, run: GOLDEN=overwrite bin/test
        and read the diff before committing it.
      MESSAGE
    end
  end

  test "every golden file belongs to a case" do
    orphans = Dir[File.join(GOLDEN_DIR, "*.html")].map { |path| File.basename(path, ".html") } - CASES.keys

    assert_empty orphans, "golden files with no case: #{orphans.join(", ")}"
  end
end
