# frozen_string_literal: true

require "maquina_stream/version"
require "maquina_stream/errors"
require "maquina_stream/configuration"
require "maquina_stream/registries"
require "maquina_stream/streamable"
require "maquina_stream/renderer"
require "maquina_stream/document"
require "maquina_stream/block"
require "maquina_stream/broadcaster"
require "maquina_stream/frame"
require "maquina_stream/manifest"
require "maquina_stream/sanitizer"
require "maquina_stream/components"
require "maquina_stream/engine" if defined?(Rails::Engine)

module MaquinaStream
  extend Registries

  # Components destined for maquina_components, vendored inside the engine for
  # now. See docs/component-scope.md.
  VENDORED_COMPONENTS = %i[attachment code_block suggestion snippet].freeze

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def reset_configuration!
      @config = Configuration.new
    end
  end
end
