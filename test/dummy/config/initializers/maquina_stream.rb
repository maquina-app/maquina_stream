# frozen_string_literal: true

MaquinaStream.configure do |c|
  # Host seams: the engine resolves and authorizes nothing on its own.
  c.find_stream = ->(sid) { Message.find_by(id: sid) }
  c.authorize   = ->(record, _request) { record.present? }
end
