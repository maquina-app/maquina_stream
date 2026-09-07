# frozen_string_literal: true

require "test_helper"
require "support/broadcast_recorder"
require "ruby_llm"
require "ruby_llm/test"
require "nexo"

RubyLLM::Models.singleton_class.prepend(RubyLLM::Test::ResolveWithTestProvider)

# A Nexo agent run, streamed.
#
# The open question this closes: whether a tool call is its own streamable
# record or a block inside the assistant's message. Decided 2026-09-07 — its
# own record — and this is what the decision costs and buys.
class NexoTest < ActiveSupport::TestCase
  # Nexo hands the block ruby_llm's own tool-call and tool-result objects. These
  # are those shapes, not stand-ins for the agent: the agent itself is real in
  # the last test.
  ToolCall = Struct.new(:name, :arguments, keyword_init: true)
  ToolResult = Struct.new(:name, :content, keyword_init: true)

  # An agent is anything that answers `prompt` and yields progress. Injecting
  # one is how the tool loop becomes deterministic without stubbing a method.
  class ScriptedAgent
    Response = Struct.new(:content, keyword_init: true)

    def initialize(events, answer)
      @events = events
      @answer = answer
    end

    def prompt(_text, **)
      @events.each { |type, payload| yield(type, payload) }
      Response.new(content: @answer)
    end
  end

  setup do
    RubyLLM::Test.reset
    RubyLLM.configure { |c| c.openai_api_key = "test" }
    @recorders = {}
  end

  teardown { RubyLLM::Test.reset }

  test "each tool call is a record of its own, sealed on its own" do
    agent = ScriptedAgent.new(
      [
        [:tool_call, ToolCall.new(name: "read_file", arguments: {path: "README.md"})],
        [:tool_result, ToolResult.new(name: "read_file", content: "# Title\n")]
      ],
      "I read the file.\n"
    )

    records = Message.stream_agent_run(agent, "read the readme", conversation_id: 7, broadcaster: recorder)

    assert_equal %w[tool assistant], records.map(&:role)
    assert_equal "read_file", records.first.tool_name

    records.each do |record|
      refute record.reload.maquina_stream_open?, "#{record.role} was left open; a client waits forever for that frame"
      assert_equal "complete", record.stream_status
    end

    assert_includes records.first.maquina_stream_buffer, "README.md"
    assert_includes records.last.maquina_stream_buffer, "I read the file"
  end

  test "two tool calls open two streams, and one sealing does not seal the other" do
    agent = ScriptedAgent.new(
      [
        [:tool_call, ToolCall.new(name: "glob", arguments: {pattern: "*.rb"})],
        [:tool_call, ToolCall.new(name: "grep", arguments: {q: "def"})],
        [:tool_result, ToolResult.new(name: "glob", content: "a.rb\nb.rb\n")],
        [:tool_result, ToolResult.new(name: "grep", content: "3 matches\n")]
      ],
      "Done.\n"
    )

    records = Message.stream_agent_run(agent, "search", conversation_id: 8, broadcaster: recorder)
    tools = records.select { |r| r.role == "tool" }

    assert_equal %w[glob grep], tools.map(&:tool_name)
    assert tools.all? { |t| t.reload.stream_status == "complete" }

    # The point of separate records: each one's sequence is its own, so a frame
    # lost on one stream cannot make the other look like it has a gap.
    assert_equal tools.map(&:maquina_stream_id).uniq.length, tools.length
  end

  test "a tool that never returns is sealed as errored, not left open" do
    agent = ScriptedAgent.new(
      [[:tool_call, ToolCall.new(name: "shell", arguments: {cmd: "sleep 1000"})]],
      "I could not finish.\n"
    )

    records = Message.stream_agent_run(agent, "run", conversation_id: 9, broadcaster: recorder)
    tool = records.find { |r| r.role == "tool" }

    assert_equal "errored", tool.reload.stream_status
    refute tool.maquina_stream_open?
  end

  test "a tool result with no announced call still gets a record" do
    agent = ScriptedAgent.new(
      [[:tool_result, ToolResult.new(name: "cached_lookup", content: "42\n")]],
      "I already had it.\n"
    )

    records = Message.stream_agent_run(agent, "search", conversation_id: 10, broadcaster: recorder)

    assert_equal %w[tool assistant], records.map(&:role)
    assert_includes records.first.maquina_stream_buffer, "42"
  end

  test "tool output renders as a code block, through the same pipeline" do
    agent = ScriptedAgent.new(
      [
        [:tool_call, ToolCall.new(name: "read_file", arguments: {path: "a.rb"})],
        [:tool_result, ToolResult.new(name: "read_file", content: "puts 1\n")]
      ],
      "Done.\n"
    )

    tool = Message.stream_agent_run(agent, "read", conversation_id: 11, broadcaster: recorder).first
    html = MaquinaStream.render(tool).to_s

    assert_includes html, "data-ms-code"
    assert_includes html, "data-ms-block-digest", "a tool record has to be repairable like any other"
  end

  # The real class, so the bridge is written against Nexo's actual signature
  # rather than against what this test believes it to be.
  test "a real Nexo agent streams its answer" do
    RubyLLM::Test.stub_response("I reviewed the module.\n")

    agent = Class.new(Nexo::Agent) do
      model "gpt-4.1-nano"
      instructions "Be brief."
    end.new

    records = Message.stream_agent_run(agent, "review", conversation_id: 12, broadcaster: recorder)

    assert_equal %w[assistant], records.map(&:role)
    assert_includes records.last.maquina_stream_buffer, "I reviewed the module"
  end

  private
    # The transport seam again: unit tests, no cable.
    def recorder
      ->(message) { MaquinaStream::Broadcaster.new(message, transport: BroadcastRecorder.new) }
    end
end
