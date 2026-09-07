# frozen_string_literal: true

Rails.application.routes.draw do
  mount MaquinaStream::Engine => "/maquina_stream"
end
