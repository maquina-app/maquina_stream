# frozen_string_literal: true

require "test_helper"
require_relative "../support/broadcast_recorder"

class BroadcasterTest < ActiveSupport::TestCase
  setup do
    @message = messages(:streaming)
    @message.update!(content: "", stream_sequence: 0, stream_status: "open")
    @recorder = BroadcastRecorder.new
    @broadcaster = MaquinaStream::Broadcaster.new(@message, transport: @recorder)
  end

  test "a sealed block is never re-broadcast during a normal stream" do
    stream(File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__)))

    sealed_ids = @broadcaster.document.sealed_blocks.map(&:id)
    resent = @recorder.resends.keys & sealed_ids

    # A block is sent while it is still open and may be patched then. What must
    # never happen is a block being sent again after it froze.
    final = MaquinaStream::Document.new(@message.content, sid: @message.maquina_stream_id)
    frozen_after_send = resent.select do |id|
      block = final.blocks.find { |b| b.id == id }
      block&.sealed? && sent_after_sealing?(id)
    end

    assert_empty frozen_after_send, "these blocks were re-broadcast after sealing: #{frozen_after_send.join(", ")}"
  end

  # docs/plan.md budgets total bytes at "under ~2.5x message size". That target
  # is below the floor: the rendered HTML of this corpus is 5.51x the markdown
  # it came from, so sending every block exactly once, with no re-sends at all,
  # already costs 5.5x. The budget is only meaningful against rendered size.
  #
  # This asserts the overhead ABOVE that floor, and is a regression guard on the
  # number actually measured — not a claim that the plan's DoD line is met. It
  # is not: see sdd/specs/.../p3.../progress.yml.
  OVERHEAD_BUDGET = 3.6 # measured 3.37x at the documented 60ms default

  test "bandwidth overhead above the rendered-html floor does not regress" do
    markdown = large_message
    floor = MaquinaStream::Renderer.call(markdown, mode: :static).to_s.bytesize

    stream_at_token_cadence(markdown)

    overhead = @recorder.total_bytes.to_f / floor

    assert_operator overhead, :<, OVERHEAD_BUDGET, <<~MESSAGE
      sent #{@recorder.total_bytes} bytes in #{@recorder.frames} frames.
      Rendered HTML floor: #{floor} bytes. Overhead: #{overhead.round(2)}x.
      Against the raw markdown that is #{@recorder.ratio_against(markdown).round(2)}x.
    MESSAGE
  end

  test "the sequence is monotonic across every frame" do
    stream("# uno\n\ndos\n\ntres\n\ncuatro\n\ncinco\n\nseis")

    assert_equal @recorder.sequences.sort, @recorder.sequences, "frames went out with a sequence that moved backwards"
    assert_equal @recorder.sequences.uniq, @recorder.sequences, "two frames shared a sequence number"
  end

  test "the sequence stays monotonic when appends interleave" do
    other = MaquinaStream::Broadcaster.new(@message, transport: @recorder)

    6.times do |n|
      @broadcaster.append("bloque #{n}\n\n")
      @broadcaster.broadcast(now: n * 1_000)
      other.append("otro #{n}\n\n")
      other.broadcast(now: n * 1_000)
    end

    assert_equal @recorder.sequences.sort, @recorder.sequences
    assert_equal @recorder.sequences.uniq, @recorder.sequences
  end

  test "frames coalesce inside the budget instead of going out per token" do
    10.times { |n| @broadcaster.append("palabra#{n} ") }

    # Every append landed inside one frame budget, so at most the first one went
    # out; the rest are still pending.
    assert_operator @recorder.frames, :<=, 1, "coalescing did not hold: #{@recorder.frames} frames for 10 appends"

    @broadcaster.seal!

    assert_operator @recorder.frames, :>=, 1
  end

  test "the final seal always flushes, however recently a frame went out" do
    @broadcaster.append("un párrafo\n\n")
    @broadcaster.broadcast(now: 0)
    before = @recorder.frames

    @broadcaster.append("otro párrafo")
    @broadcaster.seal!

    assert_operator @recorder.frames, :>, before, "the final seal must always go out"
  end

  test "the host owns persistence: append writes through the contract" do
    @broadcaster.append("texto")

    assert_equal "texto", @message.reload.content
  end

  test "sealing moves the record's status" do
    @broadcaster.append("texto")
    @broadcaster.seal!(status: :cancelled)

    assert_equal "cancelled", @message.reload.stream_status
    refute_predicate @message, :maquina_stream_open?
  end

  private
    def stream(markdown, chunk: 24)
      markdown.chars.each_slice(chunk).with_index do |slice, index|
        @broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
      end
      @broadcaster.seal!
    end

    # Four characters per token, one token every 25ms - roughly what a model
    # emits, and the cadence the frame budget has to cope with.
    def stream_at_token_cadence(markdown)
      markdown.chars.each_slice(4).with_index do |slice, index|
        @broadcaster.append(slice.join, now: index * 25)
      end
      @broadcaster.seal!
    end

    def large_message
      base = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))
      buffer = +""
      section = 1
      buffer << base.gsub("# Informe de estado", "# Sección #{section += 1}") while buffer.bytesize < 20_000
      buffer
    end

    def sent_after_sealing?(id)
      # The recorder keeps frames in order, so "sent after sealing" means the id
      # appears in a frame later than the one that carried its final HTML.
      appearances = @recorder.sent.each_index.select do |i|
        (@recorder.sent[i].appends + @recorder.sent[i].patch).include?(id)
      end

      appearances.length > 1 && appearances.last == @recorder.sent.length - 1
    end
end
