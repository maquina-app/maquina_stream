# frozen_string_literal: true

# The dummy app is a harness, not an app: it has no migrations and its database
# is in memory. The test suite loads the schema itself; a dev server has to do
# the same or every page 500s on a missing table.
#
# It reloads on a stale schema as well as a missing one. Without migrations,
# a column added to db/schema.rb would otherwise never reach a database file
# that already exists, and the failure lands far from the cause — an
# UnknownAttributeError from a page that looks unrelated.
Rails.application.config.after_initialize do
  next unless Rails.env.development?

  connection = ActiveRecord::Base.connection
  columns = connection.table_exists?(:messages) ? connection.columns(:messages).map(&:name) : []
  expected = %w[conversation_id content role tool_name stream_sequence stream_status]

  unless expected.all? { |column| columns.include?(column) }
    ActiveRecord::Schema.verbose = false
    load Rails.root.join("db/schema.rb")

    # A little history to look at.
    12.times do |n|
      Message.create!(
        content: "# Message #{n + 1}\n\nBody of message #{n + 1}, with **bold** and `code`.",
        stream_sequence: n,
        stream_status: "complete"
      )
    end
  end
end
