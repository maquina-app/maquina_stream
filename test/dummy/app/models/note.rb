# frozen_string_literal: true

# Deliberately incomplete host: it has a buffer column and nothing else, so the
# contract methods backed by missing columns raise ContractError.
class Note < ActiveRecord::Base
  include MaquinaStream::Streamable

  maquina_stream buffer: :body,
                 stream_for: ->(n) { [:notes, n.id] }
end
