# frozen_string_literal: true

module MaquinaStream
  # Phase 2 (render pipeline) renders the requested blocks as a Turbo Stream,
  # one morph per id in params[:ids].
  class BlocksController < ApplicationController
    def index
      head :not_implemented
    end
  end
end
