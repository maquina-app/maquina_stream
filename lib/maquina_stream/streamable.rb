# frozen_string_literal: true

require "active_support/concern"

module MaquinaStream
  # Host contract for a streamable record. The host owns persistence; the
  # engine never guesses a broadcast target and never invents authorization.
  #
  # ```ruby
  # class Message < ApplicationRecord
  #   include MaquinaStream::Streamable
  #
  #   maquina_stream buffer: :content,
  #                  stream_for: ->(m) { [m.conversation, :messages] }
  # end
  # ```
  #
  # The macro generates the contract methods when the column names match (see
  # docs/engine-contract.md). Anything the host defines itself wins, and a
  # method whose backing column is missing raises ContractError naming the
  # method, the column and the class.
  #
  # ## What the columns must be
  #
  # | Method | Column it reads |
  # |---|---|
  # | `#maquina_stream_buffer`, `#maquina_stream_append` | whatever `buffer:` named |
  # | `#maquina_stream_sequence`, `#maquina_stream_advance` | `stream_sequence`, an integer |
  # | `#maquina_stream_open?`, `#maquina_stream_seal!`, `#maquina_stream_status` | `stream_status`, a string holding `open` / `complete` / `cancelled` / `errored` / `timed_out` |
  #
  # `#maquina_stream_id` needs no column — it is `to_param`. `#maquina_stream_target`
  # needs none either; it calls the `stream_for:` lambda.
  #
  # ## The generated methods
  #
  # | Method | Returns |
  # |---|---|
  # | `#maquina_stream_id` | `String`, stable and unique per message |
  # | `#maquina_stream_buffer` | `String`, the raw markdown written so far |
  # | `#maquina_stream_append(text)` | the whole buffer after appending and persisting |
  # | `#maquina_stream_sequence` | `Integer`, monotonic, one per frame that went out |
  # | `#maquina_stream_advance` | `Integer`, the next sequence number, incremented atomically |
  # | `#maquina_stream_open?` | `Boolean` |
  # | `#maquina_stream_status` | the recorded end state as a Symbol, or `nil` while open |
  # | `#maquina_stream_seal!(status: :complete)` | the status Symbol it sealed with |
  # | `#maquina_stream_target` | the Turbo broadcast target, from `stream_for:` |
  #
  # Each is documented on Streamable::Generated. Defining any of them in the
  # model body overrides the generated one — the macro `include`s a module, so
  # the class body always wins.
  module Streamable
    extend ActiveSupport::Concern

    # The column `#maquina_stream_sequence` and `#maquina_stream_advance` read.
    SEQUENCE_COLUMN = :stream_sequence

    # The column `#maquina_stream_open?`, `#maquina_stream_status` and
    # `#maquina_stream_seal!` read.
    STATUS_COLUMN = :stream_status

    # The one value of STATUS_COLUMN that means the stream is still being
    # written. Everything else is a seal.
    OPEN_STATUS = "open"
    # A stream that timed out is not the same as one that errored: nothing went
    # wrong, the model simply stopped answering, and the partial text it did
    # produce is still worth keeping and replaying.
    SEAL_STATUSES = %i[complete cancelled errored timed_out].freeze

    # Every method a host must answer to. The macro generates all of them; a
    # host that cannot use the macro implements this list itself.
    CONTRACT_METHODS = %i[
      maquina_stream_id
      maquina_stream_buffer
      maquina_stream_append
      maquina_stream_sequence
      maquina_stream_advance
      maquina_stream_open?
      maquina_stream_seal!
      maquina_stream_target
    ].freeze

    included do
      class_attribute :maquina_stream_buffer_column, instance_writer: false
      class_attribute :maquina_stream_target_resolver, instance_writer: false
    end

    class_methods do
      # Declares this model streamable and generates the contract methods.
      #
      # ```ruby
      # maquina_stream buffer: :content,
      #                stream_for: ->(m) { [m.conversation, :messages] }
      # ```
      #
      # `buffer:` names the column holding the raw markdown. `stream_for:` is a
      # callable receiving the record and returning the Turbo broadcast target
      # — the engine never guesses one, because who may listen to a stream is
      # the host's question and not the engine's.
      #
      # The generated methods arrive through an included module, so anything
      # the class body defines wins over them.
      def maquina_stream(buffer:, stream_for:)
        self.maquina_stream_buffer_column = buffer.to_sym
        self.maquina_stream_target_resolver = stream_for

        include Generated
      end

      # Names the contract methods this class cannot satisfy — the generated
      # ones whose column is missing and that the host has not defined itself.
      #
      # Returns an Array of method names, empty when the contract is complete.
      # Worth asserting in a host's own test suite: the alternative is finding
      # out mid-stream, when the ContractError raises inside a broadcast.
      def maquina_stream_contract_gaps
        Generated.instance_methods.filter_map do |method|
          column = Generated::REQUIRED_COLUMNS[method]
          next if column.nil?

          column = maquina_stream_buffer_column if column == :buffer
          method unless maquina_stream_column?(column)
        end
      end

      # Whether this model has the named column. Answers `false` rather than
      # raising when the database is unreachable — the contract check must not
      # be the thing that breaks a boot.
      def maquina_stream_column?(column)
        column_names.include?(column.to_s)
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        false
      end
    end

    # The host contract, generated by the `maquina_stream` macro. Included, so
    # a host method defined in the class body overrides it.
    #
    # These are the methods the engine calls on a record — Broadcaster,
    # Manifest, Export and MaquinaStream.render between them use nothing else.
    # A host that cannot use the macro implements this module's public methods
    # itself and never includes it.
    module Generated
      REQUIRED_COLUMNS = {
        maquina_stream_buffer: :buffer,
        maquina_stream_append: :buffer,
        maquina_stream_sequence: SEQUENCE_COLUMN,
        maquina_stream_open?: STATUS_COLUMN,
        maquina_stream_seal!: STATUS_COLUMN
      }.freeze

      # A stable String, unique per message, used to build every DOM id in the
      # message and to look the record back up in a repair request. Defaults to
      # `to_param`.
      def maquina_stream_id
        to_param.to_s
      end

      # The raw markdown written so far, as a String. Never HTML: the buffer is
      # what the model wrote, and rendering it is the engine's job.
      #
      # Raises ContractError when the column named by `buffer:` does not exist.
      def maquina_stream_buffer
        maquina_stream_read(buffer_column, :maquina_stream_buffer).to_s
      end

      # Appends `text` to the buffer, persists it, and returns the whole
      # buffer.
      #
      # The host owns persistence, which is why this and not the broadcaster
      # writes. Broadcaster#append calls it first and only then has something
      # to broadcast.
      #
      # Raises ContractError when the buffer column does not exist.
      def maquina_stream_append(text)
        column = buffer_column
        maquina_stream_require_column!(column, :maquina_stream_append)
        update!(column => "#{public_send(column)}#{text}")
        maquina_stream_buffer
      end

      # The current frame sequence number, as an Integer. Monotonic. It moves
      # once per frame that actually goes out, not once per append — the client
      # uses it to notice that it missed one.
      def maquina_stream_sequence
        maquina_stream_read(SEQUENCE_COLUMN, :maquina_stream_sequence).to_i
      end

      # Increments the sequence and returns the new value.
      #
      # Added in Phase 3. The sequence is documented as "incremented per frame",
      # but the Broadcaster cannot write host state directly without
      # contradicting "host owns persistence" - so it asks, through the
      # contract, and the host's database does the incrementing atomically.
      # That is also what keeps it monotonic under concurrent appends.
      def maquina_stream_advance
        maquina_stream_require_column!(SEQUENCE_COLUMN, :maquina_stream_advance)
        self.class.where(id: id).update_all("#{SEQUENCE_COLUMN} = #{SEQUENCE_COLUMN} + 1")
        reload.maquina_stream_sequence
      end

      # The recorded end state as a Symbol — one of SEAL_STATUSES — for replay
      # and export. Nil while still open.
      #
      # Export reads this to decide whether to append a status footer: a
      # cancelled message that exports as though it were complete is a lie in a
      # file somebody keeps.
      def maquina_stream_status
        return nil if maquina_stream_open?

        maquina_stream_read(STATUS_COLUMN, :maquina_stream_status)&.to_sym
      end

      # Whether the stream is still being written.
      #
      # This is what decides render mode and what decides cacheability: an open
      # message is never cached, because it is about to change.
      def maquina_stream_open?
        maquina_stream_read(STATUS_COLUMN, :maquina_stream_open?).to_s == OPEN_STATUS
      end

      # Closes the stream and returns the status Symbol it sealed with.
      #
      # `status:` must be one of SEAL_STATUSES: `:complete`, `:cancelled`,
      # `:errored` or `:timed_out`. Anything else raises ArgumentError.
      #
      # Sealing only records the status. Broadcaster#seal! is what also emits
      # the final frame, and that frame is never coalesced and never skipped —
      # so a host seals through the broadcaster, not through this directly,
      # unless it means to close a stream silently.
      def maquina_stream_seal!(status: :complete)
        unless SEAL_STATUSES.include?(status.to_sym)
          raise ArgumentError, "status must be one of #{SEAL_STATUSES.join(", ")}, got #{status.inspect}"
        end

        maquina_stream_require_column!(STATUS_COLUMN, :maquina_stream_seal!)
        update!(STATUS_COLUMN => status.to_s)
        status.to_sym
      end

      # The Turbo broadcast target, from the `stream_for:` callable the macro
      # was given. Whatever that callable returns is passed straight to
      # `Turbo::StreamsChannel`.
      #
      # Raises ContractError when `stream_for:` is not callable: the broadcast
      # target belongs to the host, and the engine never guesses one.
      def maquina_stream_target
        resolver = self.class.maquina_stream_target_resolver
        unless resolver.respond_to?(:call)
          raise ContractError, <<~MESSAGE
            #{self.class.name} does not supply #maquina_stream_target: `stream_for:`
            is not callable. The broadcast target belongs to the host — the engine
            never guesses one. See docs/engine-contract.md.
          MESSAGE
        end

        resolver.call(self)
      end

      private
        def buffer_column
          self.class.maquina_stream_buffer_column
        end

        def maquina_stream_read(column, method)
          maquina_stream_require_column!(column, method)
          public_send(column)
        end

        def maquina_stream_require_column!(column, method)
          return if self.class.maquina_stream_column?(column)

          raise ContractError, <<~MESSAGE
            #{self.class.name} does not satisfy MaquinaStream::Streamable: ##{method}
            needs a `#{column}` column, and #{self.class.name} has none. Add the column,
            or define ##{method} on #{self.class.name} yourself.
            See docs/engine-contract.md.
          MESSAGE
        end
    end
  end
end
