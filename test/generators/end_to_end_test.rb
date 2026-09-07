# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/maquina_stream/install/install_generator"
require "generators/maquina_stream/streamable/streamable_generator"
require_relative "../support/host_skeleton"

# The generators produce something that WORKS, not something that looks right.
#
# A host is built out of the two generators and nothing else — the migration,
# the model, the initializer and the mount all come from them — and then one
# message is streamed through it: appended, framed, sealed, rendered, looked
# back up through the generated `find_stream`, and addressed through the
# generated mount.
#
# It runs in a subprocess because a Rails application initializes once per
# process and this suite already holds test/dummy. That is the whole reason for
# the indirection; everything asserted below is what the generated application
# actually did.
class MaquinaStream::GeneratedHostEndToEndTest < Rails::Generators::TestCase
  include HostSkeleton

  tests MaquinaStream::Generators::InstallGenerator
  destination File.join(Dir.tmpdir, "maquina_stream_end_to_end")
  setup :prepare_destination

  BOOT = File.expand_path("../support/generated_host_boot.rb", __dir__)

  test "a host built by the generators streams one message end to end" do
    build_host destination_root
    generate MaquinaStream::Generators::InstallGenerator
    generate MaquinaStream::Generators::StreamableGenerator, ["Message"]

    result = boot_generated_host

    # The migration satisfies the contract the engine checks.
    assert_empty result["contract_gaps"]
    assert_includes result["columns"], "content"
    assert_includes result["columns"], "stream_sequence"
    assert_includes result["columns"], "stream_status"

    # The model macro reads and writes through those columns.
    assert_equal "# Hola\n\nUn párrafo con **negritas** y un [enlace](https://example.com).\n\n```ruby\nputs 1\n```\n",
      result["buffer"]
    assert_equal false, result["open"]
    assert_equal "complete", result["status"]
    assert_operator result["sequence"], :>, 0

    # Frames went out, and exactly one of them was the seal.
    assert_operator result["frames"], :>, 0
    assert_equal 1, result["final_frames"]

    # The document a browser holds after applying every frame: rendered HTML,
    # never markdown, block-addressed and sanitized.
    dom = result["client_dom"].values.join
    assert_match(/<h1 id="ms-1-b0"[^>]*data-ms-block/, dom)
    assert_match(/<strong>negritas<\/strong>/, dom)
    assert_match(/<a href="https:\/\/example\.com"[^>]*rel="noopener noreferrer">enlace<\/a>/, dom)
    assert_match(/data-ms-code/, dom)
    refute_match(/```/, dom)
    # Spanish is the engine's default locale, and the generated host says so
    # by not saying anything.
    assert_match(/aria-label="Copiar el código"/, dom)

    # And the same document rendered from the buffer outside any request.
    assert_match(/data-ms-code-lang="ruby"/, result["document"])

    # The seams the generators wrote. `find_stream` was filled in by the
    # streamable generator; `authorize` is still the stub, and it denies.
    assert result["find_stream_resolves"], "the generated find_stream did not resolve the record"
    assert_equal false, result["authorize_answers"]

    # The mount the install generator put in config/routes.rb: the engine's
    # two repair routes are reachable through the host's route set.
    assert_equal "/maquina_stream", result["mount_path"]
    assert_equal({"controller" => "maquina_stream/manifests", "action" => "show", "sid" => "1"},
      result["manifest_route"])
    assert_equal({"controller" => "maquina_stream/blocks", "action" => "index", "sid" => "1"},
      result["blocks_route"])
  end

  private
    def generate(generator, args = [])
      capture(:stdout) { generator.start(args, destination_root: destination_root) }
    end

    def boot_generated_host
      output = IO.popen([RbConfig.ruby, BOOT, destination_root], err: [:child, :out], &:read)

      assert_predicate $?, :success?, "the generated host failed to boot:\n#{output}"

      line = output.lines.find { |candidate| candidate.start_with?("MAQUINA_STREAM_E2E ") }
      refute_nil line, "the generated host printed no result:\n#{output}"

      JSON.parse(line.delete_prefix("MAQUINA_STREAM_E2E "))
    end
end
