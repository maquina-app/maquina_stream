# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/maquina_stream/install/install_generator"
require_relative "../support/host_skeleton"

# Everything here asserts on files the generator produced in a throwaway
# application, never on the template strings it produced them from.
class MaquinaStream::InstallGeneratorTest < Rails::Generators::TestCase
  include HostSkeleton

  tests MaquinaStream::Generators::InstallGenerator
  destination File.join(Dir.tmpdir, "maquina_stream_install_generator")
  setup :prepare_destination

  test "a stock host gets every wire" do
    build_host destination_root
    run_generator

    assert_file "config/initializers/maquina_stream.rb"
    assert_file "config/routes.rb", /mount MaquinaStream::Engine => "\/maquina_stream"/
    assert_file "config/importmap.rb", /pin "@hotwired\/turbo-rails", to: "turbo.min.js"/
    assert_file "app/javascript/controllers/index.js", /registerMaquinaStreamControllers\(application\)/
    assert_file "app/views/layouts/application.html.erb" do |layout|
      assert_match %r{stylesheet_link_tag "maquina_stream/reveal"}, layout
      assert_match %r{stylesheet_link_tag "maquina_stream/themes/light"}, layout
      assert_match %r{stylesheet_link_tag "maquina_stream/themes/dark"}, layout
      # Injected inside the head, not appended after the document.
      assert_match %r{maquina_stream/themes/dark.*</head>}m, layout
    end
  end

  test "the generated initializer leaves both host seams stubbed" do
    build_host destination_root
    run_generator

    assert_file "config/initializers/maquina_stream.rb" do |initializer|
      assert_match(/c\.find_stream = ->\(sid\) \{ raise NotImplementedError/, initializer)
      assert_match(/c\.authorize = ->\(record, request\) \{ false \}/, initializer)
      assert_match(/denies every repair request/, initializer)
    end
  end

  test "the generated initializer names every configuration option with its default" do
    build_host destination_root
    run_generator

    initializer = host_file(destination_root, "config/initializers/maquina_stream.rb")
    options = MaquinaStream::Configuration.new.public_methods(false).grep(/=\z/).map { |writer| writer.to_s.chomp("=") }

    options.each do |option|
      assert_match(/^\s*#?\s*c\.#{option} =/, initializer,
        "config.#{option} is documented nowhere in the generated initializer")
    end
  end

  test "running twice changes nothing twice" do
    build_host destination_root
    run_generator
    first = snapshot

    run_generator

    assert_equal first, snapshot
    assert_equal 1, host_file(destination_root, "config/routes.rb").scan("MaquinaStream::Engine").length
    assert_equal 1, host_file(destination_root, "config/importmap.rb").scan("@hotwired/turbo-rails").length
    assert_equal 1, host_file(destination_root, "app/javascript/controllers/index.js").scan("registerMaquinaStreamControllers(application)").length
    assert_equal 1, host_file(destination_root, "app/views/layouts/application.html.erb").scan("maquina_stream/reveal").length
  end

  test "an existing initializer is never clobbered" do
    build_host destination_root
    mine = "# mine\nMaquinaStream.configure { |c| c.seal_lag = 9 }\n"
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    File.write(File.join(destination_root, "config/initializers/maquina_stream.rb"), mine)

    output = run_generator

    assert_equal mine, host_file(destination_root, "config/initializers/maquina_stream.rb")
    assert_match(/skip.*already exists/, output)
  end

  test "a host that already pins turbo is left alone" do
    build_host destination_root, overwrite: {
      "config/importmap.rb" => %(pin "@hotwired/turbo-rails", to: "turbo.min.js"\n)
    }

    output = run_generator

    assert_equal 1, host_file(destination_root, "config/importmap.rb").scan("@hotwired/turbo-rails").length
    assert_match(/skip.*already pinned/, output)
  end

  test "a host without turbo-rails is told loudly rather than pinned at a gem it lacks" do
    build_host destination_root, overwrite: {
      "Gemfile" => %(source "https://rubygems.org"\n\ngem "rails"\n)
    }

    output = run_generator

    refute_match(/@hotwired\/turbo-rails/, host_file(destination_root, "config/importmap.rb"))
    assert_match(/turbo-rails is not in this application/, output)
    assert_match(/every repair fails silently inside a catch/, output)
    assert_match(/bundle add turbo-rails/, output)
  end

  test "a host with no importmap is told what to do by hand" do
    build_host destination_root, without: ["config/importmap.rb"]

    output = run_generator

    assert_no_file "config/importmap.rb"
    assert_match(/by hand.*config\/importmap\.rb/, output)
    assert_match(/pin "@hotwired\/turbo-rails"/, output)
    # And the rest of the install still happened.
    assert_file "config/routes.rb", /MaquinaStream::Engine/
  end

  test "a host with no stimulus entrypoint is told what to do by hand" do
    build_host destination_root, without: [
      "app/javascript/controllers/index.js",
      "app/javascript/application.js"
    ]

    output = run_generator

    assert_no_file "app/javascript/controllers/index.js"
    assert_match(/by hand/, output)
    assert_match(/registerMaquinaStreamControllers\(application\)/, output)
  end

  test "a host with no layout is told what to do by hand" do
    build_host destination_root, without: ["app/views/layouts/application.html.erb"]

    output = run_generator

    assert_no_file "app/views/layouts/application.html.erb"
    assert_match(%r{stylesheet_link_tag "maquina_stream/reveal"}, output)
  end

  test "application.js is the fallback entrypoint when there is no controllers index" do
    build_host destination_root,
      without: ["app/javascript/controllers/index.js"],
      overwrite: {"app/javascript/application.js" => <<~JS}
        import { Application } from "@hotwired/stimulus"
        const application = Application.start()
      JS

    run_generator

    assert_file "app/javascript/application.js", /registerMaquinaStreamControllers\(application\)/
  end

  test "deferred renderer pins are opt-in and always carry preload false" do
    build_host destination_root

    run_generator ["--deferred-renderers"]

    assert_file "config/importmap.rb" do |importmap|
      assert_match(/pin "mermaid", to: "[^"]+", preload: false/, importmap)
      assert_match(/pin "katex", to: "[^"]+", preload: false/, importmap)
      assert_match(/importmap-rails preloads by default/, importmap)
    end
  end

  test "deferred renderer pins are not generated unless asked for" do
    build_host destination_root
    run_generator

    refute_match(/mermaid/, host_file(destination_root, "config/importmap.rb"))
  end

  test "deferred renderer pins are not duplicated on a second run" do
    build_host destination_root
    run_generator ["--deferred-renderers"]
    run_generator ["--deferred-renderers"]

    assert_equal 1, host_file(destination_root, "config/importmap.rb").scan('pin "mermaid"').length
  end

  private
    # Every generated file and its bytes, so "idempotent" is asserted against
    # the whole tree rather than against the lines a test remembered to check.
    def snapshot
      Dir.glob(File.join(destination_root, "**/*"), File::FNM_DOTMATCH)
        .select { |path| File.file?(path) }
        .sort
        .to_h { |path| [path.delete_prefix(destination_root), File.read(path)] }
    end
end
