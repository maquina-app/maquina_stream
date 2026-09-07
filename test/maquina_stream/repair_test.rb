# frozen_string_literal: true

require "test_helper"
require_relative "../support/frame_dropper"

# Deltas are an optimization; correctness lives here.
#
# Phase 3 deliberately broadcasts less than the whole truth — it patches the
# open tail only, and leaves a block that reinterprets behind the seal pointer
# wrong on the client. These tests are what make that safe to do.
class RepairTest < ActiveSupport::TestCase
  setup do
    @message = messages(:streaming)
    @message.update!(content: "", stream_sequence: 0, stream_status: "open")
  end

  # The chaos test. Flakiness here is a failure, not a flake, so it runs over
  # several seeds rather than one lucky one.
  test "every run converges after dropping 30% of frames" do
    markdown = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))

    (1..8).each do |seed|
      @message.update!(content: "", stream_sequence: 0, stream_status: "open")
      dropper = FrameDropper.new(percentage: 30, seed: seed)
      broadcaster = MaquinaStream::Broadcaster.new(@message, transport: dropper)

      markdown.chars.each_slice(12).with_index do |slice, index|
        broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
      end
      broadcaster.seal!

      assert_operator dropper.drop_count, :>, 0, "seed #{seed} dropped nothing, so it proved nothing"

      repaired = repair(dropper.client_dom)
      truth = static_blocks

      assert_equal truth, repaired,
        "seed #{seed} did not converge after repair: #{diff_summary(truth, repaired)}"
    end
  end

  test "a client that missed everything converges from a cold manifest" do
    stream("# Uno\n\nDos.\n\nTres.\n\nCuatro.\n\nCinco.")

    repaired = repair({})

    assert_equal static_blocks, repaired
  end

  test "the manifest asks for nothing when the client is already correct" do
    stream("# Uno\n\nDos.\n\nTres.\n\nCuatro.")

    manifest = MaquinaStream::Manifest.for(@message)

    assert_empty manifest.diff(manifest.entries), "a client in agreement must not be told to fetch anything"
  end

  test "the manifest asks only for the blocks that actually differ" do
    stream("# Uno\n\nDos.\n\nTres.\n\nCuatro.")

    manifest = MaquinaStream::Manifest.for(@message)
    stale = manifest.entries.map.with_index { |(id, digest), index| index == 1 ? [id, "stale"] : [id, digest] }

    assert_equal [manifest.entries[1].first], manifest.diff(stale)
  end

  # The property that makes periodic keyframes affordable at all.
  test "manifest size is independent of message length" do
    sizes = {}

    [2_000, 20_000, 100_000].each do |target|
      @message.update!(content: grown_to(target), stream_sequence: 1, stream_status: "open")
      sizes[target] = MaquinaStream::Manifest.for(@message).to_h.to_json.bytesize
    end

    # The message grows 50x across this range. Listing every sealed block made
    # the manifest grow 47.9x with it — 88KB for a 100KB message, sent every
    # keyframe. Windowed, it is flat.
    growth = sizes.values.last.to_f / sizes.values.first
    message_growth = 100_000.0 / 2_000

    assert_operator growth, :<, 1.5,
      "manifest grew #{growth.round(2)}x while the message grew #{message_growth.round(1)}x: #{sizes.inspect}"
  end

  test "sealed blocks only: the open tail is never in the manifest" do
    stream("# Uno\n\nDos.\n\nTres.\n\nCuatro.")

    document = MaquinaStream::Document.new(@message.content, sid: @message.maquina_stream_id)
    manifest_ids = MaquinaStream::Manifest.for(@message).entries.map(&:first)

    refute_includes manifest_ids, document.open_block.id,
      "an unsealed block is still moving; asking the client to chase it is the cost the seal pointer exists to avoid"
  end

  private
    def stream(markdown, drop: 0)
      dropper = FrameDropper.new(percentage: drop, seed: 7)
      broadcaster = MaquinaStream::Broadcaster.new(@message, transport: dropper)

      markdown.chars.each_slice(12).with_index do |slice, index|
        broadcaster.append(slice.join, now: index * (MaquinaStream.config.frame_budget_ms + 1))
      end
      broadcaster.seal!
      dropper
    end

    # What the repair path does: diff the manifest, fetch what differs, apply it.
    def repair(client_dom)
      manifest = MaquinaStream::Manifest.for(@message)
      client_digests = client_dom.map { |id, html| [id, Digest::SHA256.hexdigest(html)[0, 16]] }
      wanted = manifest.diff(client_digests)

      document = MaquinaStream::Document.new(
        @message.content, sid: @message.maquina_stream_id, mode: :static
      )
      served = document.blocks.select { |block| wanted.include?(block.id) }

      repaired = client_dom.dup
      served.each { |block| repaired[block.id] = block.html }

      # A client keeps nothing the server no longer claims: the morph removes it.
      repaired.slice(*document.sealed_blocks.map(&:id))
    end

    def static_blocks
      MaquinaStream::Document.new(@message.content, sid: @message.maquina_stream_id, mode: :static)
        .sealed_blocks.to_h { |block| [block.id, block.html] }
    end

    def grown_to(bytes)
      base = File.read(File.expand_path("../fixtures/markdown/kitchen_sink.md", __dir__))
      buffer = +""
      section = 0
      buffer << base.gsub("# Informe de estado", "# Sección #{section += 1}") while buffer.bytesize < bytes
      buffer
    end

    def diff_summary(truth, repaired)
      missing = truth.keys - repaired.keys
      extra = repaired.keys - truth.keys
      changed = truth.keys.select { |id| repaired.key?(id) && repaired[id] != truth[id] }
      "missing=#{missing.inspect} extra=#{extra.inspect} changed=#{changed.inspect}"
    end
end
