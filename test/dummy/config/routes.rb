# frozen_string_literal: true

Rails.application.routes.draw do
  mount MaquinaStream::Engine => "/maquina_stream"

  # Harness only. See HarnessController.
  get "harness" => "harness#show"
  get "harness/repair" => "harness#repair", :as => :harness_repair
  get "harness/deferred" => "harness#deferred", :as => :harness_deferred
  get "harness/reveal" => "harness#reveal", :as => :harness_reveal
  get "harness/reveal/stream" => "harness#reveal_stream", :as => :harness_reveal_stream
  get "history" => "history#index", :as => :history
end
