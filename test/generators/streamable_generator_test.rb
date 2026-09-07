# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/maquina_stream/install/install_generator"
require "generators/maquina_stream/streamable/streamable_generator"
require_relative "../support/host_skeleton"

class MaquinaStream::StreamableGeneratorTest < Rails::Generators::TestCase
  include HostSkeleton

  tests MaquinaStream::Generators::StreamableGenerator
  destination File.join(Dir.tmpdir, "maquina_stream_streamable_generator")
  setup :prepare_destination

  SCHEMA_WITH_MESSAGES = <<~RUBY
    ActiveRecord::Schema[8.0].define(version: 1) do
      create_table "messages", force: :cascade do |t|
        t.integer "conversation_id"
        t.text "content", default: "", null: false
        t.datetime "created_at", null: false
      end
    end
  RUBY

  test "a host with no table at all gets a create_table carrying every contract column" do
    installed_host
    run_generator ["Message"]

    assert_migration "db/migrate/create_messages.rb" do |migration|
      assert_match(/create_table :messages do \|t\|/, migration)
      assert_match(/t\.text :content, null: false, default: ""/, migration)
      assert_match(/t\.integer :stream_sequence, null: false, default: 0/, migration)
      assert_match(/t\.string :stream_status, null: false, default: "open"/, migration)
      assert_match(/t\.timestamps/, migration)
    end
  end

  # The columns are read out of Streamable, so a contract that grows a column
  # grows it here too. This is the assertion that notices if it ever does not.
  test "the migration carries exactly the columns the contract requires" do
    installed_host
    run_generator ["Message"]

    required = MaquinaStream::Streamable::Generated::REQUIRED_COLUMNS.values.uniq.map do |column|
      (column == :buffer) ? :content : column
    end

    migration = File.read(Dir.glob(File.join(destination_root, "db/migrate/*_create_messages.rb")).sole)
    required.each do |column|
      assert_match(/[:. ]#{column}[,\s]/, migration, "the migration does not create #{column}")
    end
  end

  test "every column the contract requires has a definition in the generator" do
    contract = MaquinaStream::Streamable::Generated::REQUIRED_COLUMNS.values.uniq
    known = MaquinaStream::Generators::StreamableGenerator::COLUMN_DEFINITIONS.keys

    assert_empty contract - known,
      "MaquinaStream::Streamable requires columns the streamable generator cannot create"
  end

  test "a table that already exists gets add_column for only the columns it lacks" do
    installed_host(schema: SCHEMA_WITH_MESSAGES)
    run_generator ["Message"]

    assert_migration "db/migrate/add_maquina_stream_to_messages.rb" do |migration|
      assert_match(/add_column :messages, :stream_sequence, :integer, null: false, default: 0/, migration)
      assert_match(/add_column :messages, :stream_status, :string, null: false, default: "open"/, migration)
      # `content` is already there; adding it again is what a hand-copied
      # column list does.
      refute_match(/:content/, migration)
      refute_match(/create_table/, migration)
    end
  end

  test "a table that already satisfies the contract gets no migration at all" do
    complete = SCHEMA_WITH_MESSAGES.sub(
      't.datetime "created_at", null: false',
      't.integer "stream_sequence"' + "\n" + '    t.string "stream_status"'
    )
    installed_host(schema: complete)

    output = run_generator ["Message"]

    assert_empty Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
    assert_match(/already has every contract column/, output)
  end

  test "the model is created with the include and the macro" do
    installed_host
    run_generator ["Message"]

    assert_file "app/models/message.rb" do |model|
      assert_match(/class Message < ApplicationRecord/, model)
      assert_match(/include MaquinaStream::Streamable/, model)
      assert_match(/maquina_stream buffer: :content,/, model)
      assert_match(/stream_for: ->\(record\) \{ record \}/, model)
      assert_match(/the engine never guesses one/, model)
    end
  end

  test "an existing model is injected into, never clobbered" do
    installed_host
    write_host "app/models/message.rb", <<~RUBY
      class Message < ApplicationRecord
        belongs_to :conversation

        def summary = content.truncate(80)
      end
    RUBY

    run_generator ["Message"]

    assert_file "app/models/message.rb" do |model|
      assert_match(/belongs_to :conversation/, model)
      assert_match(/def summary/, model)
      assert_match(/^  include MaquinaStream::Streamable$/, model)
      assert_match(/^  maquina_stream buffer: :content,$/, model)
    end
  end

  test "the install generator's find_stream stub is filled in" do
    installed_host
    run_generator ["Message"]

    assert_file "config/initializers/maquina_stream.rb" do |initializer|
      assert_match(/^  c\.find_stream = ->\(sid\) \{ Message\.find_by\(id: sid\) \}$/, initializer)
      refute_match(/NotImplementedError/, initializer)
      # authorize is not touched: it is the one thing no generator may guess.
      assert_match(/c\.authorize = ->\(record, request\) \{ false \}/, initializer)
    end
  end

  test "a find_stream the host already wrote is left alone" do
    installed_host
    mine = %(MaquinaStream.configure { |c| c.find_stream = ->(sid) { Note.find(sid) } }\n)
    write_host "config/initializers/maquina_stream.rb", mine

    output = run_generator ["Message"]

    assert_equal mine, host_file(destination_root, "config/initializers/maquina_stream.rb")
    assert_match(/not the generated stub/, output)
  end

  test "running twice changes nothing twice" do
    installed_host
    run_generator ["Message"]
    first = snapshot

    output = run_generator ["Message"]

    assert_equal first, snapshot
    assert_match(/already generated/, output)
    assert_match(/already streamable/, output)
    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*.rb")).length
  end

  test "the buffer column is the host's to name" do
    installed_host
    run_generator ["Note", "--buffer=body"]

    assert_migration "db/migrate/create_notes.rb", /t\.text :body, null: false, default: ""/
    assert_file "app/models/note.rb", /maquina_stream buffer: :body,/
  end

  test "the broadcast target is the host's to name" do
    installed_host
    run_generator ["Message", "--stream-for=[:conversation, record.conversation_id, :messages]"]

    assert_file "app/models/message.rb",
      /stream_for: ->\(record\) \{ \[:conversation, record\.conversation_id, :messages\] \}/
  end

  private
    # A host that has already run the install generator, which is the only
    # order in which these two make sense.
    def installed_host(schema: nil)
      build_host destination_root
      write_host "db/schema.rb", schema if schema
      capture(:stdout) do
        MaquinaStream::Generators::InstallGenerator.start([], destination_root: destination_root)
      end
    end

    def write_host(path, contents)
      full = File.join(destination_root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
    end

    def snapshot
      Dir.glob(File.join(destination_root, "**/*"), File::FNM_DOTMATCH)
        .select { |path| File.file?(path) }
        .sort
        .to_h { |path| [path.delete_prefix(destination_root), File.read(path)] }
    end
end
