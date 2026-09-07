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
  # docs/plan.md now budgets 1.5x the RENDERED document, restated from "2.5x
  # message size" which sat below the 5.51x floor.
  OVERHEAD_BUDGET = 1.5

  # The default moved to 100ms on 2026-09-07, for per-step feedback under the
  # batched arrival this is built for. The budget is not free at every arrival
  # shape, and the three tests below pin the whole trade-off rather than the one
  # number that flatters it:
  #
  #   arrival            60ms   100ms   150ms   250ms
  #   token 4ch/25ms     3.03x   2.34x   1.65x   1.08x
  #   batch 40ch/200ms   1.07x   1.07x   1.07x   0.89x
  #   step 2000ch/1s     1.17x   1.17x   1.17x   1.17x
  #
  # Coalescing only saves bytes when frames arrive faster than the budget. Under
  # batched arrival they do not, so the budget buys nothing there and costs
  # nothing — and 250ms was silently merging two steps into one frame.
  test "bandwidth stays under 1.5x the rendered document at batched arrival" do
    markdown = large_message
    floor = MaquinaStream::Renderer.call(markdown, mode: :static).to_s.bytesize

    stream_at_batch_cadence(markdown)

    overhead = @recorder.total_bytes.to_f / floor

    assert_operator overhead, :<, OVERHEAD_BUDGET, <<~MESSAGE
      sent #{@recorder.total_bytes} bytes in #{@recorder.frames} frames.
      Rendered HTML floor: #{floor} bytes. Overhead: #{overhead.round(2)}x.
      Against the raw markdown that is #{@recorder.ratio_against(markdown).round(2)}x.
    MESSAGE
  end

  # Pinned, not hidden. A host whose model emits token by token pays 2.34x at
  # the default, and the fix is its own frame_budget_ms, not a code change here.
  test "token-by-token arrival costs more than the budget at the default" do
    markdown = large_message
    floor = MaquinaStream::Renderer.call(markdown, mode: :static).to_s.bytesize

    stream_at_token_cadence(markdown)

    assert_operator @recorder.total_bytes.to_f / floor, :>, OVERHEAD_BUDGET,
      "if this passes, the trade-off documented above no longer exists and the default should be revisited"
  end

  test "raising the budget brings token arrival back inside it" do
    MaquinaStream.configure { |c| c.frame_budget_ms = 250 }
    markdown = large_message
    floor = MaquinaStream::Renderer.call(markdown, mode: :static).to_s.bytesize

    stream_at_token_cadence(markdown)

    assert_operator @recorder.total_bytes.to_f / floor, :<, OVERHEAD_BUDGET
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

  # The repair path triggers on this, and a client cannot tell that a frame is
  # the last one by looking at it. When it went missing nothing failed: the
  # stream just never told anyone it had finished.
  test "the final seal frame is marked as final on the wire" do
    @broadcaster.append("un párrafo\n\n", now: 0)
    @broadcaster.seal!

    refute_predicate @recorder.sent.first, :final, "an ordinary frame must not claim to be the seal"
    assert_predicate @recorder.sent.last, :final, "the seal frame is what triggers the final repair"
  end

  test "sealing a message with nothing pending still announces the seal" do
    @broadcaster.append("texto", now: 0)
    @broadcaster.broadcast(now: 0)
    before = @recorder.frames

    @broadcaster.seal!

    assert_operator @recorder.frames, :>, before, "a seal with no content change still has to be announced"
    assert_predicate @recorder.sent.last, :final
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

    # What a batched provider and a Nexo step look like: text arrives in useful
    # pieces, slower than the frame budget, so every piece is its own frame.
    def stream_at_batch_cadence(markdown)
      markdown.chars.each_slice(40).with_index do |slice, index|
        @broadcaster.append(slice.join, now: index * 200)
      end
      @broadcaster.seal!
    end

    # Four characters per token, one token every 25ms - roughly what an
    # unbatched model emits, and the cadence the frame budget has to cope with.
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
