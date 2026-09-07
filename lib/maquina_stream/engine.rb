# frozen_string_literal: true

module MaquinaStream
  # The Rails engine. Mount it for the repair endpoints:
  #
  # ```ruby
  # mount MaquinaStream::Engine => "/maquina_stream"
  # ```
  #
  # It contributes two routes (see MaquinaStream::ManifestsController and
  # MaquinaStream::BlocksController), the engine's stylesheets and JavaScript,
  # and its importmap pins. It contributes no migrations and no models: the
  # host owns persistence.
  class Engine < ::Rails::Engine
    isolate_namespace MaquinaStream

    initializer "maquina_stream.streamable" do
      ActiveSupport.on_load(:active_record) do
        # Hosts `include MaquinaStream::Streamable` themselves; requiring it
        # here only guarantees it is loaded before any host model boots.
        require "maquina_stream/streamable"
      end
    end

    # NoBuild: the engine's JavaScript ships as source and is served by the
    # asset pipeline, pinned into the host's importmap. There is no package.json
    # and no npm dependency anywhere in this gem.
    #
    # Both initializers are no-ops when the host has neither propshaft/sprockets
    # nor importmap-rails: the engine's Ruby side does not require them.
    initializer "maquina_stream.assets" do |app|
      next unless app.config.respond_to?(:assets)

      app.config.assets.paths << root.join("app/javascript")
      app.config.assets.paths << root.join("app/assets/stylesheets")
    end

    initializer "maquina_stream.importmap", before: "importmap" do |app|
      next unless app.config.respond_to?(:importmap)

      app.config.importmap.paths << root.join("config/importmap.rb")
      # Cache-bust the host's importmap when engine JavaScript changes in dev.
      app.config.importmap.cache_sweepers << root.join("app/javascript")
    end
  end
end
