# frozen_string_literal: true

module MaquinaStream
  class Engine < ::Rails::Engine
    isolate_namespace MaquinaStream

    initializer "maquina_stream.streamable" do
      ActiveSupport.on_load(:active_record) do
        # Hosts `include MaquinaStream::Streamable` themselves; requiring it
        # here only guarantees it is loaded before any host model boots.
        require "maquina_stream/streamable"
      end
    end
  end
end
