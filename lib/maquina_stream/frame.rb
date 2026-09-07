# frozen_string_literal: true

module MaquinaStream
  # One broadcast: what changed since the last one.
  #
  #   appends  blocks the browser has never seen, sent whole
  #   patch    unsealed blocks whose HTML moved since the last frame
  #
  # `patch` is a list rather than the single open block that docs/api-surface.md
  # implied. The seal lag keeps `seal_lag` blocks unsealed at all times, and any
  # of them can still change — a paragraph two blocks back becomes a heading
  # when its underline arrives. Sending only the last one would leave the others
  # wrong until a repair.
  class Frame
    attr_reader :seq, :appends, :patch

    def initialize(seq:, appends: [], patch: [], final: false)
      @seq = seq
      @appends = appends
      @patch = patch
      @final = final
    end

    # The final seal. It is marked on the wire because the repair path triggers
    # on it: docs/design.md calls this the trigger that makes all intra-stream
    # drift cosmetic and self-correcting, and a client cannot know a frame is
    # the last one by looking at it.
    def final? = @final

    def empty?
      appends.empty? && patch.empty?
    end

    def blocks
      appends + patch
    end

    def bytesize
      blocks.sum { |block| block.html.to_s.bytesize }
    end

    def to_h
      {
        seq: seq,
        final: final?,
        appends: appends.map(&:id),
        patch: patch.map(&:id)
      }
    end
  end
end
