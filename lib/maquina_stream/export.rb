# frozen_string_literal: true

module MaquinaStream
  # A whole message, back out as markdown.
  #
  #   MaquinaStream::Export.markdown(message)
  #
  # The buffer already is markdown, so export is mostly a question of what to do
  # with the parts that are not clean:
  #
  # * **A cancelled stream ends mid-token.** The raw buffer would export a half
  #   written bold run or an unterminated fence, so the buffer is repaired first
  #   — the same preprocessor the renderer uses, so an export matches what was
  #   on screen.
  # * **Deferred content exports as its source**, which is the Phase 6 fallback,
  #   decided once and applied everywhere. A diagram exports as its ```mermaid
  #   fence, because that is what the model wrote and what another tool can read.
  #   There is nothing to substitute: rendering it would mean shipping the
  #   renderer to the server.
  #
  # A status footer is appended for anything that did not finish, because a
  # cancelled message that exports as though it were complete is a lie in a file
  # somebody keeps.
  module Export
    INCOMPLETE = %i[cancelled errored timed_out].freeze

    class << self
      def markdown(record, config: MaquinaStream.config, annotate: true)
        buffer = MaquinaRemend.call(record.maquina_stream_buffer.to_s)
        status = status_of(record)

        return buffer unless annotate && INCOMPLETE.include?(status)

        "#{buffer.rstrip}\n\n#{note_for(status, config)}\n"
      end

      private
        def status_of(record)
          return :open if record.maquina_stream_open?
          return nil unless record.respond_to?(:maquina_stream_status)

          record.maquina_stream_status&.to_sym
        end

        def note_for(status, config)
          I18n.t(
            "maquina_stream.export.#{status}",
            locale: I18n.locale || config.locale,
            default: "> [#{status}]"
          )
        end
    end
  end
end
