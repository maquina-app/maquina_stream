# frozen_string_literal: true

require "rails/generators/base"

module MaquinaStream
  module Generators
    # Wires the engine into a host: the initializer, the mount, the importmap
    # pins, the Stimulus registration and the stylesheets.
    #
    # ```sh
    # bin/rails generate maquina_stream:install
    # ```
    #
    # Every step is idempotent and none of them overwrites a host file. A step
    # whose ingredient is missing — no importmap, no Stimulus entrypoint, no
    # layout — says what to do by hand instead of failing or silently doing
    # nothing, because a generator that no-ops quietly is worse than one that
    # is not there.
    #
    # Two things it exists to prevent, both learned the hard way:
    #
    # - **Turbo must be pinned by the host.** Repair applies Turbo Stream
    #   morphs; with `window.Turbo` undefined every repair fails inside a catch
    #   and nothing in the browser says so.
    # - **A deferred-renderer pin needs `preload: false`.** importmap-rails
    #   preloads by default, which fetches the library on every page and
    #   defeats the lazy import it exists to avoid.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Wires maquina_stream into this application: initializer, mount, importmap, Stimulus, stylesheets."

      class_option :deferred_renderers, type: :boolean, default: false,
        desc: "Also pin mermaid and katex (preload: false) for the diagram and math renderers"

      INITIALIZER = "config/initializers/maquina_stream.rb"
      ROUTES = "config/routes.rb"
      IMPORTMAP = "config/importmap.rb"
      LAYOUT = "app/views/layouts/application.html.erb"

      # Where `registerMaquinaStreamControllers(application)` can go, best
      # first. Both have an `application` in scope in a stock importmap app.
      ENTRYPOINTS = %w[
        app/javascript/controllers/index.js
        app/javascript/application.js
      ].freeze

      MOUNT = 'mount MaquinaStream::Engine => "/maquina_stream"'

      TURBO_PIN = <<~RUBY
        # Required by maquina_stream: repair applies Turbo Stream morphs, and with
        # `window.Turbo` undefined every repair fails silently inside a catch.
        pin "@hotwired/turbo-rails", to: "turbo.min.js"
      RUBY

      DEFERRED_PINS = <<~RUBY
        # Libraries the client-deferred renderers import lazily. `preload: false` is
        # load-bearing: importmap-rails preloads by default, which would emit a
        # <link rel="modulepreload"> and fetch both on every page — exactly the cost
        # the lazy import inside `ms-deferred#library()` exists to avoid.
        pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/+esm", preload: false
        pin "katex", to: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.mjs", preload: false
      RUBY

      REGISTRATION = <<~JS
        // maquina_stream registers its own Stimulus identifiers rather than relying
        // on an eager-load glob: those identifiers are part of the DOM contract.
        import { registerMaquinaStreamControllers } from "maquina_stream"
        registerMaquinaStreamControllers(application)
      JS

      STYLESHEETS = <<~ERB
        <%= stylesheet_link_tag "maquina_stream/reveal" %>
        <%= stylesheet_link_tag "maquina_stream/themes/light" %>
        <%= stylesheet_link_tag "maquina_stream/themes/dark" %>
      ERB

      def create_initializer
        if exists?(INITIALIZER)
          skip INITIALIZER, "already exists — left untouched"
        else
          template "initializer.rb.tt", INITIALIZER
        end
      end

      def mount_engine
        return by_hand(ROUTES, MOUNT) unless exists?(ROUTES)
        return skip(ROUTES, "engine already mounted") if read(ROUTES).include?("MaquinaStream::Engine")

        route MOUNT
      end

      def pin_turbo
        return by_hand(IMPORTMAP, TURBO_PIN, importmap_absent_note) unless exists?(IMPORTMAP)
        return skip(IMPORTMAP, "@hotwired/turbo-rails already pinned") if read(IMPORTMAP).include?("@hotwired/turbo-rails")
        return turbo_missing unless turbo_available?

        append_to_file IMPORTMAP, "\n#{TURBO_PIN}"
      end

      def pin_deferred_renderers
        return unless options[:deferred_renderers]
        return by_hand(IMPORTMAP, DEFERRED_PINS) unless exists?(IMPORTMAP)
        return skip(IMPORTMAP, "mermaid and katex already pinned") if read(IMPORTMAP).include?('pin "mermaid"')

        append_to_file IMPORTMAP, "\n#{DEFERRED_PINS}"
      end

      def register_controllers
        entrypoint = ENTRYPOINTS.find { |path| exists?(path) && read(path).match?(/\bapplication\b/) }
        return by_hand(ENTRYPOINTS.first, REGISTRATION, entrypoint_absent_note) if entrypoint.nil?
        return skip(entrypoint, "controllers already registered") if read(entrypoint).include?("registerMaquinaStreamControllers")

        append_to_file entrypoint, "\n#{REGISTRATION}"
      end

      def link_stylesheets
        return by_hand(LAYOUT, STYLESHEETS) unless exists?(LAYOUT)
        return skip(LAYOUT, "stylesheets already linked") if read(LAYOUT).include?("maquina_stream/reveal")

        inject_into_file LAYOUT, STYLESHEETS.gsub(/^/, "    "), before: %r{^\s*</head>}
      end

      def report_the_two_seams
        say ""
        say "maquina_stream is wired. Two things are still yours:", :green
        say ""
        say "  1. #{INITIALIZER} — `authorize` is a stub that denies everything."
        say "     Until you replace it every repair request is refused, which is safe"
        say "     and also broken: the browser can never repair a message."
        say ""
        say "  2. bin/rails generate maquina_stream:streamable Message"
        say "     — the migration and the model macro, and it fills in `find_stream`."
        say ""
      end

      private
        def exists?(path)
          File.exist?(File.join(destination_root, path))
        end

        def read(path)
          File.read(File.join(destination_root, path))
        end

        def skip(path, why)
          say_status :skip, "#{path}: #{why}", :yellow
        end

        # A missing ingredient is reported loudly and with the exact content to
        # paste. Silence here is what left our own dummy app without Turbo.
        def by_hand(path, content, note = nil)
          say_status :"by hand", path, :red
          say note if note
          say ""
          say content.gsub(/^/, "    ")
          say ""
        end

        # Turbo is the host's pin, but pinning it against a gem that is not
        # there produces a 404 on every page — so it is only added when the
        # host's own Gemfile has turbo-rails. The question is about the
        # application being generated into, not about this process.
        def turbo_available?
          gemfile.match?(/^\s*gem ["']turbo-rails["']/)
        end

        def gemfile
          exists?("Gemfile") ? read("Gemfile") : ""
        end

        def turbo_missing
          say_status :error, "turbo-rails is not in this application", :red
          say <<~MESSAGE

            maquina_stream requires Turbo. Repair applies Turbo Stream morphs, and
            with `window.Turbo` undefined every repair fails silently inside a catch:
            the message simply stops being correct and nothing says so.

                bundle add turbo-rails
                bin/rails turbo:install
                bin/rails generate maquina_stream:install

          MESSAGE
        end

        def importmap_absent_note
          "No config/importmap.rb. maquina_stream ships JavaScript by importmap and " \
            "has no build step; with a bundler, import its source from app/javascript " \
            "in the gem. Either way Turbo has to be loaded:"
        end

        def entrypoint_absent_note
          "No Stimulus entrypoint with an `application` in scope. Add this wherever " \
            "you call `Application.start()`:"
        end
    end
  end
end
