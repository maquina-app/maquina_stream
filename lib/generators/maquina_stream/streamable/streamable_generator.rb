# frozen_string_literal: true

require "rails/generators/named_base"
require "rails/generators/migration"
require "maquina_stream/streamable"

module MaquinaStream
  module Generators
    # Makes one model streamable: the migration carrying the columns the
    # contract requires, and the `include` plus macro in the model.
    #
    # ```sh
    # bin/rails generate maquina_stream:streamable Message
    # ```
    #
    # Per model, because a host may have several — an assistant message and a
    # tool call are two streams, not one.
    #
    # The columns come from MaquinaStream::Streamable itself rather than from a
    # list copied out of the documentation, so a contract that gains a column
    # gains it here too. A column the contract requires and this generator has
    # no definition for raises rather than being quietly left out.
    class StreamableGenerator < Rails::Generators::NamedBase
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds the maquina_stream contract columns and the model macro to one model."

      class_option :buffer, type: :string, default: "content",
        desc: "The column holding the raw markdown"
      class_option :stream_for, type: :string, default: "record",
        desc: "Ruby for the Turbo broadcast target, written against `record`"

      INITIALIZER = "config/initializers/maquina_stream.rb"

      # The stub the install generator writes, and what replaces it.
      FIND_STREAM_STUB = /^(\s*)c\.find_stream = ->\(sid\) \{ raise NotImplementedError.*\}$/

      # How to create each column the contract asks for. Keyed by the column
      # name Streamable declares, plus `:buffer` for the one the host names.
      # Streamable::Generated::REQUIRED_COLUMNS is the source of truth for
      # *which* columns; this is the source of truth for their shape.
      COLUMN_DEFINITIONS = {
        :buffer => {type: :text, default: "", null: false},
        Streamable::SEQUENCE_COLUMN => {type: :integer, default: 0, null: false},
        Streamable::STATUS_COLUMN => {type: :string, default: Streamable::OPEN_STATUS, null: false}
      }.freeze

      def self.next_migration_number(dirname)
        ActiveRecord::Migration.next_migration_number(current_migration_number(dirname) + 1)
      end

      def create_migration_file
        return say_status(:skip, "db/migrate: #{table_name} already has every contract column", :yellow) if missing_columns.empty?
        return say_status(:skip, "db/migrate: #{migration_name} already generated", :yellow) if migration_generated?

        migration_template "migration.rb.tt", "db/migrate/#{migration_name}.rb"
      end

      def create_or_update_model
        if File.exist?(File.join(destination_root, model_path))
          return say_status(:skip, "#{model_path}: already streamable", :yellow) if model_source.include?("MaquinaStream::Streamable")

          inject_into_class model_path, class_name, model_macro
        else
          template "model.rb.tt", model_path
        end
      end

      # The install generator leaves `find_stream` raising. Now there is a
      # model to point it at — but only the generated stub is ever replaced, so
      # a host that already wrote its own is never clobbered.
      def fill_in_find_stream
        return say_status(:skip, "#{INITIALIZER}: not found — set c.find_stream yourself", :yellow) unless File.exist?(File.join(destination_root, INITIALIZER))

        source = File.read(File.join(destination_root, INITIALIZER))
        unless source.match?(FIND_STREAM_STUB)
          return say_status(:skip, "#{INITIALIZER}: find_stream is not the generated stub", :yellow)
        end

        gsub_file INITIALIZER, FIND_STREAM_STUB, "\\1c.find_stream = ->(sid) { #{class_name}.find_by(id: sid) }"
      end

      def report_what_is_left
        say ""
        say "#{class_name} streams. What is still yours:", :green
        say ""
        say "  - `stream_for:` in #{model_path} — the Turbo broadcast target."
        say "    Who may subscribe to a stream is your question, not the engine's."
        say "  - `c.authorize` in #{INITIALIZER}, which still denies everything."
        say ""
        say "  Assert the contract in your own suite, so a missing column fails at"
        say "  test time rather than mid-stream:"
        say ""
        say "      assert_empty #{class_name}.maquina_stream_contract_gaps"
        say ""
      end

      private
        # Every column the contract needs, resolved against the buffer name the
        # host chose. Derived from Streamable, never from a copied list.
        def contract_columns
          Streamable::Generated::REQUIRED_COLUMNS.values.uniq.map do |column|
            definition = COLUMN_DEFINITIONS.fetch(column) do
              raise Rails::Generators::Error, <<~MESSAGE
                MaquinaStream::Streamable requires a `#{column}` column and this
                generator has no definition for it. The contract moved; teach
                COLUMN_DEFINITIONS the new column rather than leaving hosts to
                find out mid-stream.
              MESSAGE
            end

            definition.merge(name: (column == :buffer) ? buffer_column : column)
          end
        end

        def missing_columns
          contract_columns.reject { |column| existing_columns.include?(column[:name].to_s) }
        end

        def buffer_column
          options[:buffer].to_sym
        end

        def create_table?
          table_definition.nil?
        end

        def migration_name
          create_table? ? "create_#{table_name}" : "add_maquina_stream_to_#{table_name}"
        end

        def migration_generated?
          Dir.glob(File.join(destination_root, "db/migrate/*_#{migration_name}.rb")).any?
        end

        def migration_version
          ActiveRecord::Migration.current_version.to_s
        end

        # What db/schema.rb says this table already has. A host with no schema
        # yet gets a create_table; one whose table exists gets add_column for
        # the columns it is actually missing.
        def existing_columns
          @existing_columns ||= table_definition.to_s.scan(/t\.\w+\s+[:"']([a-z0-9_]+)/).flatten
        end

        def table_definition
          return @table_definition if defined?(@table_definition)

          @table_definition = schema[/create_table [:"']#{Regexp.escape(table_name)}["']?[^\n]*\n(.*?)\n\s*end/m, 1]
        end

        def schema
          @schema ||= begin
            path = File.join(destination_root, "db/schema.rb")
            File.exist?(path) ? File.read(path) : ""
          end
        end

        def model_path
          File.join("app/models", class_path, "#{file_name}.rb")
        end

        def model_source
          File.read(File.join(destination_root, model_path))
        end

        def model_macro
          <<~RUBY.indent(2)
            include MaquinaStream::Streamable

            # `buffer:` names the column holding the raw markdown. `stream_for:`
            # returns the Turbo broadcast target — the engine never guesses one,
            # because who may subscribe to a stream is the host's question. This
            # gives every #{singular_name} a stream of its own; a conversation-wide
            # target is usually what you want:
            #
            #   stream_for: ->(record) { [:conversation, record.conversation_id, :#{table_name}] }
            maquina_stream buffer: :#{buffer_column},
              stream_for: ->(record) { #{options[:stream_for]} }
          RUBY
        end
    end
  end
end
