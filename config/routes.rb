# frozen_string_literal: true

MaquinaStream::Engine.routes.draw do
  # Mounted at /maquina_stream by the host:
  #   GET /maquina_stream/:sid/manifest      => { seq:, blocks: [[id, digest], …] }
  #   GET /maquina_stream/:sid/blocks?ids[]= => Turbo Stream, morph per block
  scope ":sid" do
    resource :manifest, only: :show
    resources :blocks, only: :index
  end
end
