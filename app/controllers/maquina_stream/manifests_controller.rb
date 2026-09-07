# frozen_string_literal: true

module MaquinaStream
  # The snapshot the repair path diffs against: sequence plus one digest per
  # sealed block. A few hundred bytes whatever the message weighs.
  class ManifestsController < ApplicationController
    # `GET /maquina_stream/:sid/manifest` →
    # `{ seq:, cutoff:, rollup:, blocks: [[id, digest], …] }`.
    def show
      # `full=1` is the cold path: a client whose rollup disagrees with ours
      # cannot repair from the window alone and asks for everything.
      render json: Manifest.for(@record, full: params[:full].present?).to_h
    end
  end
end
