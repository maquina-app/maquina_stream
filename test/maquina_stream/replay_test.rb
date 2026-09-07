# frozen_string_literal: true

require "test_helper"
require_relative "../support/broadcast_recorder"
require_relative "../support/repair_simulator"

# Replay parity, asserted in CI rather than checked once by hand.
#
# The same renderer serves the live stream, a page reload, a replay and an
# export — that is the claim the pure-function constraint exists to make good
# on. If a reload of a finished conversation differs from what the reader
# watched arrive, the constraint bought nothing.
class ReplayTest < ActiveSupport::TestCase
  setup do
    @message = messages(:streaming)
    @message.update!(content: "", stream_sequence: 0, stream_status: "open")
  end

  test "replaying a completed message reproduces the live end state exactly" do
    markdown = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))
    live = RepairSimulator.new(@message).repair(stream(markdown))
    simulator = RepairSimulator.new(@message)

    refute_empty live
    assert_equal simulator.truth.keys.sort, live.keys.sort, "the reader ended up with a different set of blocks"

    # Exact parity, byte for byte. It used to be content-only, because blocks
    # carried streaming chrome that repair could not correct; they no longer
    # carry any.
    simulator.truth.each do |id, html|
      assert_equal html, live[id], "block #{id} differs between the live stream and a reload"
    end
  end

  test "every block the client holds carries the digest the server would compute" do
    live = RepairSimulator.new(@message).repair(stream("# Uno\n\nDos.\n\nTres.\n\nCuatro."))
    truth = RepairSimulator.new(@message).truth

    truth.each do |id, html|
      assert_equal digest_of(html), digest_of(live[id]),
        "block #{id} would be fetched again on the next repair, forever"
    end
  end

  # The delta stream on its own does NOT converge, and that is deliberate.
  # Phase 3 patches the open tail only, so a block that changes after it stops
  # being the tail — a heading whose text completes in the same frame that opens
  # the paragraph below it — stays wrong on the client until repair.
  #
  # Asserting this keeps the seam honest: if deltas ever did converge alone, the
  # repair path would be dead code nobody noticed, and if this test is ever
  # "fixed" by making deltas complete, the bandwidth budget goes with it.
  test "the delta stream alone leaves the client diverged" do
    live = stream("# Informe de estado

Un párrafo.

Otro párrafo.

Y otro más.")
    truth = RepairSimulator.new(@message).truth

    diverged = truth.reject { |id, html| live[id] == html }

    refute_empty diverged,
      "deltas converged on their own; either the tail patching changed or this corpus no longer reinterprets"
  end

  test "a cancelled stream replays into the partial state it ended in" do
    stream("# Informe\n\nUn párrafo completo.\n\nOtro que se corta a mit", status: :cancelled)

    assert_equal "cancelled", @message.reload.stream_status
    assert_equal :cancelled, @message.maquina_stream_status

    html = MaquinaStream::Renderer.call(@message.content, mode: :static)

    assert_includes html, "Un párrafo completo"
    assert_includes html, "se corta a mit", "the partial tail is part of the record, not something to hide"
  end

  test "every seal status is recorded and readable" do
    %i[complete cancelled errored timed_out].each do |status|
      @message.update!(content: "texto", stream_status: "open")
      @message.maquina_stream_seal!(status: status)

      assert_equal status, @message.maquina_stream_status
      refute_predicate @message, :maquina_stream_open?
    end
  end

  test "an unknown seal status is refused rather than stored" do
    assert_raises(ArgumentError) { @message.maquina_stream_seal!(status: :exploded) }
  end

  # ---------------------------------------------------------------- export

  test "export returns the buffer as markdown" do
    @message.update!(content: "# Título\n\nTexto.\n", stream_status: "complete")

    assert_equal "# Título\n\nTexto.\n", MaquinaStream::Export.markdown(@message)
  end

  test "export repairs a buffer that was cut mid-token" do
    @message.update!(content: "Un párrafo con **negrita a medias", stream_status: "cancelled")

    exported = MaquinaStream::Export.markdown(@message)

    assert_includes exported, "**negrita a medias**", "an export of a cancelled stream is still markdown"
  end

  test "export annotates a stream that did not finish" do
    @message.update!(content: "texto", stream_status: "cancelled")

    assert_match(/cancel/i, MaquinaStream::Export.markdown(@message))
    refute_match(/cancel/i, MaquinaStream::Export.markdown(@message, annotate: false))
  end

  test "export leaves a complete message unannotated" do
    @message.update!(content: "texto\n", stream_status: "complete")

    assert_equal "texto\n", MaquinaStream::Export.markdown(@message)
  end

  test "deferred content exports as its source, which is the Phase 6 fallback" do
    @message.update!(content: "```mermaid\ngraph TD; A-->B;\n```\n", stream_status: "complete")

    exported = MaquinaStream::Export.markdown(@message)

    assert_includes exported, "```mermaid"
    assert_includes exported, "graph TD; A-->B;"
  end

  private
    def content_of(html)
      Nokogiri::HTML5.fragment(html).children.find(&:element?)&.inner_html
    end

    def digest_of(html)
      Nokogiri::HTML5.fragment(html).children.find(&:element?)&.[]("data-ms-block-digest")
    end

    def stream(markdown, status: :complete)
      recorder = BroadcastRecorder.new
      broadcaster = MaquinaStream::Broadcaster.new(@message, transport: recorder)

      markdown.chars.each_slice(16).with_index do |slice, index|
        broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
      end
      broadcaster.seal!(status: status)

      # What the reader ended up with: the actual bytes of every frame, applied
      # in order, exactly as the browser applies them.
      recorder.client_dom
    end
end
