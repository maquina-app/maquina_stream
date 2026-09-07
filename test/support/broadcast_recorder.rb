# frozen_string_literal: true

# Captures every frame a Broadcaster sends and totals the bytes.
#
# Named in HANDOFF.md as a verification harness, because the bandwidth line in
# the Phase 3 DoD is otherwise an estimate. It plugs into the transport seam, so
# it records exactly what the real transport would have sent.
class BroadcastRecorder
  Sent = Struct.new(:seq, :appends, :patch, :bytes, :html, :final, keyword_init: true)

  attr_reader :sent

  def initialize
    @sent = []
  end

  def call(record:, frame:, config:)
    @sent << Sent.new(
      seq: frame.seq,
      appends: frame.appends.map(&:id),
      patch: frame.patch.map(&:id),
      bytes: frame.bytesize,
      final: frame.final?,
      # The bytes themselves, so replay parity compares what was actually sent
      # rather than what the final document says now.
      html: (frame.appends + frame.patch).to_h { |block| [block.id, block.html] }
    )
  end

  # The DOM a client holds after applying every frame in order.
  def client_dom
    sent.each_with_object({}) { |frame, dom| dom.merge!(frame.html) }
  end

  def total_bytes
    sent.sum(&:bytes)
  end

  def frames = sent.length

  def sequences = sent.map(&:seq)

  # Every block id that was sent more than once, with how many times. The Phase
  # 3 DoD says no sealed block is ever re-broadcast during a normal stream, and
  # this is what notices.
  def resends
    counts = Hash.new(0)
    sent.each { |frame| (frame.appends + frame.patch).each { |id| counts[id] += 1 } }
    counts.select { |_id, count| count > 1 }
  end

  def ratio_against(markdown)
    total_bytes.to_f / markdown.bytesize
  end
end
