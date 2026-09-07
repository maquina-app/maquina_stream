# frozen_string_literal: true

module MaquinaStream
  # Every engine request resolves the record through the host's `find_stream`
  # callable and is authorized by the host's `authorize` callable. With neither
  # configured the engine refuses: it never assumes it may serve a message.
  class ApplicationController < ActionController::Base
    before_action :set_stream_record
    before_action :authorize_stream_record

    private
      def set_stream_record
        @record = MaquinaStream.config.find_stream!(params[:sid])
        head :not_found unless @record
      end

      def authorize_stream_record
        head :forbidden unless MaquinaStream.config.authorized?(@record, request)
      end
  end
end
