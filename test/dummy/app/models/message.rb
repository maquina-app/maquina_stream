# frozen_string_literal: true

class Message < ActiveRecord::Base
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(m) { [:conversation, m.conversation_id, :messages] }
end
