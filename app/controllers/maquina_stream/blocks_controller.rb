# frozen_string_literal: true

module MaquinaStream
  # The blocks the client asked for, as morphing Turbo Stream actions.
  #
  # Only ids the message actually has are served, and only the ones requested:
  # `ids` comes from the client, so it is filtered against the document rather
  # than trusted. A request for every block is a legitimate cold repair, so the
  # count is not capped — but each id is matched, not interpolated.
  class BlocksController < ApplicationController
    def index
      requested = Array(params[:ids]).map(&:to_s).to_set
      blocks = document.blocks.select { |block| requested.include?(block.id) }

      # Rendered explicitly rather than via `render turbo_stream:`, which does
      # not count as a render when the list is empty and then looks for a
      # template that does not exist. Asking to repair nothing is a normal
      # answer to a manifest that already agreed.
      render plain: blocks.map { |block| morph(block) }.join, content_type: Mime[:turbo_stream]
    end

    private
      def document
        Document.new(
          @record.maquina_stream_buffer,
          config: MaquinaStream.config,
          sid: @record.maquina_stream_id,
          mode: @record.maquina_stream_open? ? :streaming : :static
        )
      end

      # `method: :morph` is what makes the repair silent: idiomorph patches the
      # existing node in place, so client state inside it survives and no
      # animation is triggered by a replacement that never happens.
      def morph(block)
        turbo_stream.replace(block.id, block.html, method: :morph)
      end
  end
end
