# frozen_string_literal: true

module MaquinaStream
  # One broadcast: what changed since the last one.
  #
  # | Field | What is in it |
  # |---|---|
  # | `appends` | blocks the browser has never seen, sent whole |
  # | `patch` | unsealed blocks whose HTML moved since the last frame |
  #
  # Frames come out of Broadcaster. A host reads them — to assert a bandwidth
  # budget, or to drive a transport of its own — rather than building them.
  #
  # `patch` is a list rather than a single open block. The seal lag keeps `seal_lag` blocks unsealed at all times, and any
  # of them can still change — a paragraph two blocks back becomes a heading
  # when its underline arrives. Sending only the last one would leave the others
  # wrong until a repair.
  class Frame
    # This frame's sequence number, from the host's row. Monotonic, one per
    # frame that actually went out. A client that sees a gap knows it missed
    # something.
    attr_reader :seq

    # Blocks the browser has never seen, as Block objects. Sent whole.
    attr_reader :appends

    # Unsealed blocks whose HTML moved since the last frame, as Block objects.
    # Applied by morph, keyed on id.
    attr_reader :patch

    # Builds a frame. Broadcaster does this.
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

    # Whether this frame carries nothing. An empty frame is skipped, unless it
    # is the final one.
    def empty?
      appends.empty? && patch.empty?
    end

    # Every block in this frame, appends first.
    def blocks
      appends + patch
    end

    # The HTML this frame puts on the wire, in bytes. What the bandwidth
    # budget is measured in.
    def bytesize
      blocks.sum { |block| block.html.to_s.bytesize }
    end

    # A summary: sequence, finality, and the block ids on each side. Ids
    # rather than HTML, so it stays readable in a log.
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
