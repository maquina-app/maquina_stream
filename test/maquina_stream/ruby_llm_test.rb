# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "ruby_llm/test"
require "support/broadcast_recorder"

RubyLLM::Models.singleton_class.prepend(RubyLLM::Test::ResolveWithTestProvider)

# The engine against a real model client rather than a fixture string.
#
# Everything else in this suite feeds the pipeline text this repository wrote.
# That proves the pipeline; it does not prove the seam a host actually uses, and
# the seam is where every regression in this project has been found. Here the
# text comes out of `RubyLLM::Chat` exactly as it does in a host app, with
# `ruby_llm-test`'s provider standing in for the network.
#
# `RubyLLM::Test`'s provider answers in one piece rather than in chunks. That is
# not a gap being papered over: one-shot arrival is a shape the plan measured
# (1.28x the floor, against 1.25x for token arrival) and it is what a batched
# Nexo step looks like. Token-by-token arrival is covered by the replayer, which
# streams a document one character at a time.
class RubyLlmTest < ActiveSupport::TestCase
  setup do
    RubyLLM::Test.reset
    RubyLLM.configure { |c| c.openai_api_key = "test" }
  end

  teardown { RubyLLM::Test.reset }

  test "a message streams from a chat and seals" do
    RubyLLM::Test.stub_response("# Informe\n\nUn párrafo con **negrita**.\n")

    message = Message.create!(conversation_id: 1)
    message.stream_from(RubyLLM.chat(model: "gpt-4.1-nano"), "Escribe un informe", broadcaster: recorder_for(message))

    assert_equal "complete", message.reload.stream_status
    refute message.maquina_stream_open?
    assert_includes message.maquina_stream_buffer, "**negrita**"

    document = Nokogiri::HTML5.fragment(MaquinaStream.render(message))

    assert_equal "Informe", document.at_css("h1").text
    assert document.at_css("strong")
  end

  test "what the model wrote is rendered, never trusted" do
    RubyLLM::Test.stub_response("<script>alert(1)</script>\n\n[x](javascript:alert(1))\n")

    message = Message.create!(conversation_id: 1)
    message.stream_from(RubyLLM.chat(model: "gpt-4.1-nano"), "hola", broadcaster: recorder_for(message))

    html = MaquinaStream.render(message).to_s

    refute_includes html, "<script"
    refute_includes html, "javascript:"
  end

  test "an unterminated response still renders, because remend repairs it first" do
    RubyLLM::Test.stub_response("Un **párrafo a medio")

    message = Message.create!(conversation_id: 1)
    message.stream_from(RubyLLM.chat(model: "gpt-4.1-nano"), "hola", broadcaster: recorder_for(message))

    document = Nokogiri::HTML5.fragment(MaquinaStream.render(message))

    assert document.at_css("strong"), "the model stopped mid-emphasis; the reader should not see the asterisks"
  end

  test "the broadcaster is a seam, so the bytes a chat costs can be counted" do
    RubyLLM::Test.stub_response("Uno.\n\nDos.\n\nTres.\n")

    message = Message.create!(conversation_id: 1)
    recorder = MaquinaStream::Broadcaster.new(message, transport: BroadcastRecorder.new)
    message.stream_from(RubyLLM.chat(model: "gpt-4.1-nano"), "cuenta", broadcaster: recorder)

    assert_operator recorder.transport.sent.length, :>=, 1
    assert recorder.transport.sent.last.final,
      "a stream that ends without a final frame leaves every client waiting"
  end

  private
    # The transport seam. These are unit tests: there is no cable, and the real
    # transport is what the browser harness exercises.
    def recorder_for(message)
      MaquinaStream::Broadcaster.new(message, transport: BroadcastRecorder.new)
    end

  test "a failing model still seals, and says how" do
    message = Message.create!(conversation_id: 1)

    # No response is stubbed, so the provider raises — the shape of a model that
    # times out or refuses mid-answer.
    assert_raises(RubyLLM::Test::Errors::NoResponseProvidedError) do
      message.stream_from(RubyLLM.chat(model: "gpt-4.1-nano"), "hola")
    end

    assert_equal "errored", message.reload.stream_status
    refute message.maquina_stream_open?
  end

  test "a tool call is its own record, and streams the same way" do
    RubyLLM::Test.stub_responses(
      "Consulto el clima.",
      "```json\n{\"temp\": 21}\n```\n"
    )

    chat = RubyLLM.chat(model: "gpt-4.1-nano")

    answer = Message.create!(conversation_id: 99, role: "assistant")
    answer.stream_from(chat, "¿Qué tiempo hace?", broadcaster: recorder_for(answer))

    tool = Message.create!(conversation_id: 99, role: "tool", tool_name: "weather")
    tool.stream_from(chat, "weather(city: 'CDMX')", broadcaster: recorder_for(tool))

    # Separate records, so they seal, repair and export independently — and two
    # of them can be open at once, which is what a parallel tool call is.
    refute_equal answer.maquina_stream_id, tool.maquina_stream_id
    assert_equal %w[assistant tool], Message.where(conversation_id: 99).order(:id).pluck(:role)
    assert_includes MaquinaStream.render(tool).to_s, "data-ms-code"
  end
end
