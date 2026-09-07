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
  require "propshaft"
  require "importmap-rails"
rescue LoadError
  # Running without the harness gems. The suite still passes.
end

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
  end
end
