# frozen_string_literal: true

require "test_helper"
require_relative "../support/broadcast_recorder"
require_relative "../support/repair_simulator"

# A tool call: its own record, or a block inside the message?
#
# The question came up for Nexo, whose runs are tool-call loops rather than one
# long prose answer. It looked like it might block the design. It does not —
# the contract supports both shapes, and this file is the proof, so the choice
# stays a product decision instead of becoming an engine constraint.
#
# What differs is the unit of streaming, not the machinery:
#
#   separate record  one stream target per step, sealed independently
#   one buffer       one target, steps are fenced blocks in the markdown
class AgentShapesTest < ActiveSupport::TestCase
  # ---------------------------------------------------- shape A: own record

  test "a tool call as its own Streamable record streams and seals independently" do
    thinking = Message.create!(content: "", stream_sequence: 0, stream_status: "open")
    tool = Message.create!(content: "", stream_sequence: 0, stream_status: "open")

    thinking_frames = BroadcastRecorder.new
    tool_frames = BroadcastRecorder.new

    stream(thinking, "I am going to read the file.", thinking_frames)
    stream(tool, "```json\n{\"path\": \"config/routes.rb\"}\n```", tool_frames)

    # Independent sequences, independent seals. One step failing does not
    # cancel the step before it.
    tool.maquina_stream_seal!(status: :errored)

    assert_equal :complete, thinking.maquina_stream_status
    assert_equal :errored, tool.maquina_stream_status
    refute_equal thinking.maquina_stream_id, tool.maquina_stream_id
    refute_empty thinking_frames.sent
    refute_empty tool_frames.sent

    # Each repairs against its own manifest, so a lost frame in one step never
    # drags the other into a repair.
    assert_equal RepairSimulator.new(thinking).truth, RepairSimulator.new(thinking).repair(thinking_frames.client_dom)
    assert_equal RepairSimulator.new(tool).truth, RepairSimulator.new(tool).repair(tool_frames.client_dom)
  end

  # Two steps of one run share a cable stream — that is what `stream_for:` is
  # for, and one subscription per conversation is the point. What has to differ
  # is where their frames land in the DOM.
  test "steps share a cable stream but never a DOM target" do
    first = Message.create!(content: "one", stream_status: "open")
    second = Message.create!(content: "two", stream_status: "open")

    assert_equal first.maquina_stream_target, second.maquina_stream_target,
      "steps of one conversation belong on one subscription"

    refute_equal first.maquina_stream_id, second.maquina_stream_id

    first_blocks = MaquinaStream::Document.new(first.content, sid: first.maquina_stream_id).blocks.map(&:id)
    second_blocks = MaquinaStream::Document.new(second.content, sid: second.maquina_stream_id).blocks.map(&:id)

    assert_empty first_blocks & second_blocks,
      "block ids are namespaced by message, so one step's frames cannot land in another's DOM"
  end

  # ------------------------------------------------- shape B: one buffer

  test "a tool call as a fenced block inside one message needs no engine change" do
    MaquinaStream.register_fence "tool_result", strategy: :server

    message = Message.create!(content: "", stream_sequence: 0, stream_status: "open")
    frames = BroadcastRecorder.new

    stream(message, <<~MD, frames)
      I am going to read the file.

      ```tool_result
      config/routes.rb: 12 lines
      ```

      The file defines two routes.
    MD

    document = MaquinaStream::Document.new(message.content, sid: message.maquina_stream_id, mode: :static)

    # The step is a block: it gets a stable id, a digest, and repairs like any
    # other block.
    assert_operator document.blocks.length, :>=, 3
    assert_includes document.html, "tool_result"
    assert_equal RepairSimulator.new(message).truth, RepairSimulator.new(message).repair(frames.client_dom)
  end

  test "a step that arrives while an earlier one is still open does not disturb it" do
    MaquinaStream.register_fence "tool_result", strategy: :server

    message = Message.create!(content: "", stream_sequence: 0, stream_status: "open")
    broadcaster = MaquinaStream::Broadcaster.new(message, transport: BroadcastRecorder.new)

    broadcaster.append("First step.\n\n", now: 0)
    first_pass = MaquinaStream::Document.new(message.content, sid: message.maquina_stream_id).blocks.first.digest

    broadcaster.append("```tool_result\noutput\n```\n\nSecond step.", now: 1_000)
    broadcaster.seal!

    after = MaquinaStream::Document.new(message.content, sid: message.maquina_stream_id).blocks.first.digest

    assert_equal first_pass, after,
      "an earlier step changed when a later one arrived; block ids would be unstable across a run"
  end

  private
    def stream(record, markdown, recorder)
      broadcaster = MaquinaStream::Broadcaster.new(record, transport: recorder)

      markdown.chars.each_slice(12).with_index do |slice, index|
        broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
      end
      broadcaster.seal!
    end
end
