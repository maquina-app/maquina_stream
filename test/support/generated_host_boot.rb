# frozen_string_literal: true

# Boots the application that test/generators/end_to_end_test.rb built with the
# two generators, and streams one message through it.
#
# A subprocess, because a Rails application can only be initialized once per
# process and the suite already holds test/dummy. Everything this reads —
# the migration, the model, the initializer, the mount — was written by
# `maquina_stream:install` and `maquina_stream:streamable` and by nothing else.
#
# Prints one line of JSON, prefixed, so the test can assert on what actually
# happened rather than on what the templates say.

require "json"
require "logger"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "turbo-rails"
require "maquina_stream"

APP_ROOT = ARGV.fetch(0)

module GeneratedHost
  class Application < Rails::Application
    config.root = APP_ROOT
    config.eager_load = false
    config.secret_key_base = "generated-host-secret-key-base-for-tests"
    config.logger = Logger.new(File::NULL)
    config.i18n.default_locale = :es
    config.i18n.available_locales = %i[es en]
  end
end

Rails.application.initialize!
ActiveRecord::Base.logger = nil
ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(File.join(APP_ROOT, "db/migrate")).migrate

frames = []
transport = ->(record:, frame:, config:) do
  frames << {
    seq: frame.seq,
    final: frame.final?,
    html: (frame.appends + frame.patch).to_h { |block| [block.id, block.html] }
  }
end

message = Message.create!
broadcaster = MaquinaStream::Broadcaster.new(message, transport: transport)

broadcaster.append("# Hola\n\n")
broadcaster.append("Un párrafo con **negritas** y un [enlace](https://example.com).\n\n")
broadcaster.append("```ruby\nputs 1\n```\n")
broadcaster.seal!

message.reload
routes = Rails.application.routes

puts "MAQUINA_STREAM_E2E " + JSON.generate(
  contract_gaps: Message.maquina_stream_contract_gaps.map(&:to_s),
  columns: Message.column_names,
  buffer: message.maquina_stream_buffer,
  status: message.maquina_stream_status.to_s,
  open: message.maquina_stream_open?,
  sequence: message.maquina_stream_sequence,
  frames: frames.length,
  final_frames: frames.count { |frame| frame[:final] },
  # What a browser holds after applying every frame in order.
  client_dom: frames.each_with_object({}) { |frame, dom| dom.merge!(frame[:html]) },
  # The same document rendered from the buffer, outside any request.
  document: MaquinaStream.render(message),
  # The seams the generators wrote into config/initializers/maquina_stream.rb.
  find_stream_resolves: MaquinaStream.config.find_stream.call(message.id)&.id == message.id,
  authorize_answers: MaquinaStream.config.authorize.call(message, nil),
  # The mount the install generator put in config/routes.rb: the engine's own
  # routes recognised through the host's route set.
  mount_path: routes.url_helpers.maquina_stream_path,
  manifest_route: routes.recognize_path("/maquina_stream/#{message.maquina_stream_id}/manifest", method: :get),
  blocks_route: routes.recognize_path("/maquina_stream/#{message.maquina_stream_id}/blocks", method: :get)
)
