# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# Harness only, and only when the gems are installed (the Gemfile puts them in
# :development/:test). The engine's Ruby side needs neither; its asset and
# importmap initializers no-op when they are absent.
begin
  require "turbo-rails"
  require "propshaft"
  require "importmap-rails"
  require "stimulus-rails"
rescue LoadError
  # Running without the harness gems. The suite still passes.
end

# The cable the live pages stream over, and the reason it is loaded here rather
# than unconditionally: `Turbo::StreamsChannel` is a subclass of an Action Cable
# channel, so requiring this is what makes the engine's default transport stop
# being a no-op. Every unit test hands the broadcaster a recorder instead, and
# the suite is meant to keep proving the engine rather than the wire — so the
# test environment stays exactly as it was, and only the browser harness gets a
# real cable.
require "action_cable/engine" unless ENV["RAILS_ENV"] == "test"

require "maquina_stream"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy-secret-key-base-for-tests"
    config.logger = Logger.new(File::NULL)

    # Harness only. `test/dummy/app/views/harness` is a browser fixture for the
    # Phase 5 Stimulus controllers; nothing in the engine depends on it.
    config.paths.add "app/controllers", eager_load: true
    config.paths.add "app/views"

    # Spanish is this project's default locale (CLAUDE.md); the dummy host says
    # so the way any host would, rather than the engine imposing it.
    config.i18n.default_locale = :es
    config.i18n.available_locales = %i[es en]
  end
end
