# frozen_string_literal: true

require "digest"

module MaquinaStream
  # What the browser is told a message currently *is*, in a bounded number of
  # bytes.
  #
  # ```ruby
  # { seq: 412, cutoff: 38, rollup: "7c1f…",
  #   blocks: [["ms-m8f21-b38", "a91c…"], ["ms-m8f21-b39", "4fe2…"]] }
  # ```
  #
  # Not HTML. The client diffs this against its own DOM, asks for the blocks
  # whose digests differ, and morphs only those — so repair costs what has
  # drifted rather than what the message weighs.
  #
  # ## Why it is windowed
  #
  # docs/design.md said the manifest is "a few hundred bytes regardless of
  # message size". Measured, listing every sealed block gave 1.8KB for a 2KB
  # message and 88KB for a 100KB one — it tracked length almost exactly, because
  # block count does. A keyframe every four seconds carrying 88KB is the
  # bandwidth problem the manifest was introduced to prevent.
  #
  # So the manifest carries the last `window` sealed blocks in full, plus one
  # rollup digest covering everything older. A client whose rollup matches knows
  # its history is intact and only has to consider the window; a client whose
  # rollup differs asks for the whole thing, which is rare and is what a cold
  # page load does anyway.
  #
  # Payload is then bounded by the window, not by the message.
  #
  # ## Wire format
  #
  # | Key | Meaning |
  # |---|---|
  # | `seq` | the sequence number this manifest describes |
  # | `cutoff` | how many sealed blocks fall behind the window |
  # | `rollup` | one digest covering every block behind the cutoff |
  # | `blocks` | `[[id, digest], …]` for the blocks inside the window |
  class Manifest
    # The sequence number this manifest describes.
    attr_reader :seq

    # Every sealed Block, in order — including the ones behind the window,
    # which #rollup covers and #windowed_entries omits.
    attr_reader :blocks

    # How many sealed blocks are listed in full. Everything older is covered by
    # #rollup. `Float::INFINITY` when the manifest was built with `full: true`.
    attr_reader :window

    # Builds the manifest for a record, over its current buffer.
    #
    # `full: true` drops the window and lists every sealed block — what a
    # client asks for when its #rollup disagrees with ours and the windowed
    # diff is therefore not enough. Rare, and no more expensive than the cold
    # page load it resembles.
    def self.for(record, config: MaquinaStream.config, window: nil, full: false)
      document = Document.new(
        record.maquina_stream_buffer,
        config: config,
        sid: record.maquina_stream_id,
        mode: record.maquina_stream_open? ? :streaming : :static
      )

      new(
        seq: record.maquina_stream_sequence,
        blocks: document.sealed_blocks,
        window: full ? Float::INFINITY : (window || config.manifest_window)
      )
    end

    # Builds a manifest over a list of sealed blocks. `.for` is the usual
    # entry point.
    def initialize(seq:, blocks:, window: 50)
      @seq = seq
      @blocks = blocks
      @window = window
    end

    # Every sealed block, id and digest. The wire format sends a slice of this.
    def entries
      blocks.map(&:to_manifest_entry)
    end

    # How many entries fall behind the window and are covered by #rollup
    # instead of being listed. Zero for a full manifest.
    def cutoff
      return 0 if window.infinite?

      [entries.length - window, 0].max
    end

    # The entries actually sent: everything from #cutoff onwards.
    def windowed_entries
      entries.drop(cutoff)
    end

    # One digest covering every block older than the window. Order matters: two
    # clients holding the same blocks in a different order are not in the same
    # state.
    def rollup
      Digest::SHA256.hexdigest(entries.take(cutoff).flatten.join(" "))[0, 16]
    end

    # The wire format, as a Hash. What the manifest endpoint renders.
    def to_h
      {seq: seq, cutoff: cutoff, rollup: rollup, blocks: windowed_entries}
    end

    # The wire format, as JSON.
    def to_json(*args)
      to_h.to_json(*args)
    end

    # Which of the client's blocks disagree with ours, within the window.
    #
    # Blocks the client has and we do not are not reported: the server is the
    # authority on what exists, and a stale block is removed by the morph rather
    # than by a separate instruction.
    def diff(client_digests)
      client = client_digests.to_h

      windowed_entries.filter_map do |id, digest|
        id unless client[id] == digest
      end
    end

    # True when the client's view of the history behind the window disagrees
    # with ours, and the windowed diff is therefore not enough.
    def stale_history?(client_rollup)
      cutoff.positive? && client_rollup != rollup
    end
  end
end
