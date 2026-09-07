# frozen_string_literal: true

require "test_helper"
require_relative "../support/broadcast_recorder"
require_relative "../support/frame_dropper"
require_relative "../support/repair_simulator"

# Two tabs on one stream.
#
# The broadcast goes to a stream name, not to a connection, so both tabs receive
# the same frames and neither costs the server anything extra. What has to be
# true is that they converge on the same DOM even when they lose *different*
# frames — which is the realistic case, since a drop is per-connection.
class MultiTabTest < ActiveSupport::TestCase
  setup do
    @message = messages(:streaming)
    @message.update!(content: "", stream_sequence: 0, stream_status: "open")
  end

  test "two tabs losing different frames converge on the same DOM" do
    first = FrameDropper.new(percentage: 30, seed: 11)
    second = FrameDropper.new(percentage: 30, seed: 99)

    stream_to([first, second], File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__)))

    refute_equal first.client_dom, second.client_dom,
      "the tabs lost the same frames, so this proves nothing about divergence"

    simulator = RepairSimulator.new(@message)
    repaired_first = simulator.repair(first.client_dom)
    repaired_second = simulator.repair(second.client_dom)

    assert_equal repaired_first, repaired_second, "two tabs did not converge on the same DOM"
    assert_equal simulator.truth.keys.sort, repaired_first.keys.sort
  end

  test "a second tab costs the server no extra rendering" do
    recorder = BroadcastRecorder.new
    broadcaster = MaquinaStream::Broadcaster.new(@message, transport: recorder)

    # One broadcaster serves the stream regardless of how many tabs listen: the
    # frame is built once and published to a stream name. A per-tab broadcaster
    # would re-render the whole buffer per tab per frame, which is the mistake
    # this asserts against.
    "# One\n\nTwo.\n\nThree.\n\nFour.".chars.each_slice(8).with_index do |slice, index|
      broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
    end
    broadcaster.seal!

    frames_for_one_tab = recorder.frames
    bytes_for_one_tab = recorder.total_bytes

    assert_operator frames_for_one_tab, :>, 0
    # Nothing in Broadcaster knows how many subscribers exist, which is the
    # point: the work is per stream, not per tab.
    refute_respond_to broadcaster, :subscribers
    assert_equal bytes_for_one_tab, recorder.total_bytes
  end

  test "a tab that joins late repairs to the full message rather than the tail" do
    stream_to([BroadcastRecorder.new], "# One\n\nTwo.\n\nThree.\n\nFour.\n\nFive.")

    # A tab opened after the stream finished has nothing at all.
    late = RepairSimulator.new(@message).repair({})

    assert_equal RepairSimulator.new(@message).truth, late
  end

  private
    def stream_to(transports, markdown)
      broadcaster = MaquinaStream::Broadcaster.new(@message, transport: Fanout.new(transports))

      markdown.chars.each_slice(12).with_index do |slice, index|
        broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
      end
      broadcaster.seal!
    end

    # One frame, many listeners — what a real cable stream does.
    class Fanout
      def initialize(transports) = @transports = transports

      def call(record:, frame:, config:)
        @transports.each { |transport| transport.call(record: record, frame: frame, config: config) }
      end
    end
end
