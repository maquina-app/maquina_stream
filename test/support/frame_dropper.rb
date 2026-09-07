# frozen_string_literal: true

# Drops a configurable percentage of broadcast frames, deliberately.
#
# Named in HANDOFF.md as a verification harness, and for a reason worth
# restating: without deliberate frame dropping there is no way to prove
# convergence, and the phase will report success on untested code. Action Cable
# offers no delivery guarantee, so this is not a hypothetical.
#
# It sits in the transport seam, so what it drops is exactly what the real
# transport would have sent, and what survives is what a real client would have
# received.
class FrameDropper
  attr_reader :percentage, :delivered, :dropped, :random

  def initialize(percentage: 30, seed: 1234)
    @percentage = percentage
    @delivered = []
    @dropped = []
    @random = Random.new(seed)
  end

  def call(record:, frame:, config:)
    if random.rand(100) < percentage
      dropped << frame
    else
      delivered << frame
    end
  end

  # The DOM a client would hold, having received only the frames that survived.
  #
  # Appends add a block; a patch replaces one it already has. A patch for a
  # block whose append was dropped is ignored — the client cannot patch what it
  # never received, which is exactly the divergence repair has to close.
  def client_dom
    dom = {}

    delivered.each do |frame|
      frame.appends.each { |block| dom[block.id] = block.html }
      frame.patch.each { |block| dom[block.id] = block.html if dom.key?(block.id) }
    end

    dom
  end

  def frames = delivered.length

  def drop_count = dropped.length
end
