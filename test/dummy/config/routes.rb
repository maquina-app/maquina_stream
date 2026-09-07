# frozen_string_literal: true

Rails.application.routes.draw do
  mount MaquinaStream::Engine => "/maquina_stream"

  # Harness only. See HarnessController.
  get "harness" => "harness#show"
  get "history" => "history#index", :as => :history
end
