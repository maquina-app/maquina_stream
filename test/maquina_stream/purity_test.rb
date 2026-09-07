# frozen_string_literal: true

require "test_helper"

# "Pure function, no request context" is the constraint CLAUDE.md puts on the
# renderer, and the kind of claim that rots quietly. Asserting it inside a booted
# dummy app proves very little, so this runs the pipeline in a separate process
# with ActionView and no Rails application at all.
class PurityTest < ActiveSupport::TestCase
  test "the pipeline renders in a plain ruby process with no rails application" do
    script = <<~RUBY
      require "action_view"
      require "maquina_stream"

      raise "a Rails application booted" if defined?(Rails.application) && Rails.application

      MaquinaStream.register_fence "ruby", strategy: :server
      print MaquinaStream::Renderer.call("# Título\\n\\n```ruby\\nputs 1\\n```")
    RUBY

    output = IO.popen([RbConfig.ruby, "-I", lib_path, "-e", script], err: %i[child out], &:read)

    assert_predicate $?, :success?, "the renderer needs a Rails application to run:\n#{output}"
    assert_includes output, "<h1"
    assert_includes output, %(data-ms-code-lang="ruby")
    assert_includes output, "data-ms-code-source", "components must render outside an application too"
  end

  private
    def lib_path
      File.expand_path("../../lib", __dir__)
    end
end
