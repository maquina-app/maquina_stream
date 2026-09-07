# frozen_string_literal: true

Rails.application.configure do
  config.eager_load = false
  config.consider_all_requests_local = true

  # In-process pub/sub. The live harness pages are one Puma, one browser and no
  # Redis: the async adapter is the whole cable, and a frame broadcast from the
  # request thread reaches the websocket in the same process.
  config.action_cable.cable = {"adapter" => "async"}
  config.action_cable.disable_request_forgery_protection = true

  # `flash` on the live pages, and nothing else needs a session.
  config.session_store :cookie_store, key: "_maquina_stream_harness"
end
