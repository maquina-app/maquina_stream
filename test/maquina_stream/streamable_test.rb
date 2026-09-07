# frozen_string_literal: true

require "test_helper"

class MaquinaStream::StreamableTest < ActiveSupport::TestCase
  test "the macro generates the seven contract methods" do
    message = messages(:streaming)

    MaquinaStream::Streamable::CONTRACT_METHODS.each do |method|
      assert_respond_to message, method
    end
  end

  test "id is stable and unique per message" do
    assert_equal messages(:streaming).to_param.to_s, messages(:streaming).maquina_stream_id
    assert_not_equal messages(:sealed).maquina_stream_id, messages(:streaming).maquina_stream_id
  end

  test "buffer reads the configured column" do
    assert_equal messages(:streaming).content, messages(:streaming).maquina_stream_buffer
  end

  test "append appends and persists" do
    message = messages(:streaming)
    original = message.content

    message.maquina_stream_append(" más texto")

    assert_equal "#{original} más texto", message.maquina_stream_buffer
    assert_equal "#{original} más texto", message.reload.content
  end

  test "sequence is an integer" do
    assert_equal 7, messages(:streaming).maquina_stream_sequence
  end

  test "open? follows the status column" do
    assert_predicate messages(:streaming), :maquina_stream_open?
    assert_not_predicate messages(:sealed), :maquina_stream_open?
  end

  test "seal! persists the status and returns it" do
    message = messages(:streaming)

    assert_equal :complete, message.maquina_stream_seal!
    assert_equal "complete", message.reload.stream_status
    assert_not_predicate message, :maquina_stream_open?

    assert_equal :cancelled, message.maquina_stream_seal!(status: :cancelled)
    assert_equal "cancelled", message.reload.stream_status
  end

  test "seal! rejects an unknown status" do
    assert_raises(ArgumentError) { messages(:streaming).maquina_stream_seal!(status: :whatever) }
  end

  test "target comes from the host's stream_for callable" do
    message = messages(:streaming)

    assert_equal [:conversation, message.conversation_id, :messages], message.maquina_stream_target
  end

  test "a host method overrides the generated one" do
    klass = Class.new(Message) do
      def self.name = "OverridingMessage"

      def maquina_stream_id = "custom-#{id}"
    end

    assert_equal "custom-#{messages(:streaming).id}", klass.find(messages(:streaming).id).maquina_stream_id
  end

  test "an unmet contract raises an error naming the missing method and column" do
    error = assert_raises(MaquinaStream::ContractError) { notes(:plain).maquina_stream_sequence }

    assert_match "maquina_stream_sequence", error.message
    assert_match "stream_sequence", error.message
    assert_match "Note", error.message
  end

  test "an unmet contract is reported before it is called" do
    assert_empty Message.maquina_stream_contract_gaps
    assert_equal %i[maquina_stream_sequence maquina_stream_open? maquina_stream_seal!].sort,
      Note.maquina_stream_contract_gaps.sort
  end

  test "every unmet contract method raises, and the met ones do not" do
    note = notes(:plain)

    assert_equal "sin contrato", note.maquina_stream_buffer
    assert_equal [:notes, note.id], note.maquina_stream_target

    assert_raises(MaquinaStream::ContractError) { note.maquina_stream_open? }
    assert_raises(MaquinaStream::ContractError) { note.maquina_stream_seal! }
  end
end
