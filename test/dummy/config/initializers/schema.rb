# frozen_string_literal: true

# The dummy app is a harness, not an app: it has no migrations and its database
# is in memory. The test suite loads the schema itself; a dev server has to do
# the same or every page 500s on a missing table.
Rails.application.config.after_initialize do
  next unless Rails.env.development?

  unless ActiveRecord::Base.connection.table_exists?(:messages)
    ActiveRecord::Schema.verbose = false
    load Rails.root.join("db/schema.rb")

    # A little history to look at.
    12.times do |n|
      Message.create!(
        content: "# Mensaje #{n + 1}\n\nCuerpo del mensaje #{n + 1}, con **negrita** y `código`.",
        stream_sequence: n,
        stream_status: "complete"
      )
    end
  end
end
