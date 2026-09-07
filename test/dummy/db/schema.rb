# frozen_string_literal: true

ActiveRecord::Schema[8.0].define(version: 1) do
  create_table :messages, force: true do |t|
    t.integer :conversation_id
    t.text    :content, default: "", null: false
    t.integer :stream_sequence, default: 0, null: false
    t.string  :stream_status, default: "open", null: false
    t.timestamps
  end

  create_table :notes, force: true do |t|
    t.text :body, default: "", null: false
    t.timestamps
  end
end
