# frozen_string_literal: true

require "digest"

module MaquinaStream
  # Turns a growing buffer into a stream of small patches.
  #
  #   broadcaster = MaquinaStream::Broadcaster.new(message)
  #   broadcaster.append("más texto")   # host persists, engine broadcasts
  #   broadcaster.seal!                 # final frame, always
  #
  # It remembers what the browser already has — block id to digest — and sends
  # only what moved. A block that has not changed is never re-sent, which is the
  # difference between bandwidth tracking drift and bandwidth tracking message
  # length.
  #
  # Transport is a seam. It defaults to Turbo Streams over whatever cable the
  # host configured, and a test can hand it a recorder instead; that recorder is
  # how the bandwidth budget is asserted rather than estimated.
  class Broadcaster
    attr_reader :record, :config, :transport

    def initialize(record, config: MaquinaStream.config, transport: nil)
      @record = record
      @config = config
      @transport = transport || TurboTransport.new
      @known = {}
      @tail_id = nil
      @last_flush = nil
    end

    # Host owns persistence: it appends to its own column, and only then is
    # there anything to broadcast.
    def append(text, now: monotonic_ms)
      record.maquina_stream_append(text)
      broadcast(now: now)
    end

    # The final frame is never coalesced and never skipped. Every intra-stream
    # drift becomes cosmetic and self-correcting because of this one.
    def seal!(status: :complete)
      record.maquina_stream_seal!(status: status)
      emit(now: monotonic_ms, force: true)
    end

    # Coalescing happens BEFORE the render, not after it. Building a frame means
    # rendering the whole buffer, so doing that per token and then throwing the
    # result away is how a stream becomes quadratic in message length.
    #
    # Skipping a frame costs nothing: the next one is computed against what the
    # browser actually has, so it carries the accumulated difference.
    def broadcast(now: monotonic_ms)
      return nil unless due?(now)

      emit(now: now)
    end

    # A sealed message renders in static mode, which is what takes the caret
    # off the last block.
    def document
      Document.new(
        record.maquina_stream_buffer,
        config: config,
        sid: record.maquina_stream_id,
        mode: record.maquina_stream_open? ? :streaming : :static
      )
    end

    private
      # Coalescing: frames inside the budget accumulate instead of going out one
      # per token. The budget is the host's to tune; 60ms is roughly a frame.
      def due?(now)
        return true if @last_flush.nil?

        now - @last_flush >= config.frame_budget_ms
      end

      def emit(now:, force: false)
        frame = build_frame
        return nil if frame.empty?

        @last_flush = now
        frame.blocks.each { |block| @known[block.id] = sent_digest(block) }

        # The sequence belongs to the host's row and moves once per frame that
        # actually goes out, not once per append.
        sequenced = Frame.new(seq: record.maquina_stream_advance, appends: frame.appends, patch: frame.patch)
        transport.call(record: record, frame: sequenced, config: config)
        sequenced
      end

      # Append what the browser has never seen; patch the open tail, and nothing
      # else.
      #
      # A block often takes its final form in the very frame that opens the one
      # below it — a heading completes as the paragraph after it begins — and so
      # stops being the tail while the client still holds "Informe de est".
      # Sending it once more at that handover was measured: it costs a full
      # extra copy of the message, 1.248x -> 2.41x, because it happens once per
      # block. The repair path already fixes it for free, because that change is
      # a CONTENT change and content is exactly what a manifest digest covers.
      #
      # What repair does not fix is presentation chrome (data-ms-reveal, the
      # block state) on a block that sealed after it stopped being the tail: the
      # digest ignores chrome by design. That divergence is left, and corrected
      # by the next reload. See the Phase 7 progress notes.
      def build_frame
        current = document
        tail = current.blocks.last

        appends = current.blocks.reject { |block| @known.key?(block.id) }
        patch = []

        if tail && changed?(tail)
          patch << tail
          appends.delete_if { |block| block.id == tail.id }
        end

        Frame.new(seq: record.maquina_stream_sequence, appends: appends, patch: patch)
      end

      # What the client holds is bytes, so "changed" is measured on the bytes.
      # The manifest's digest answers a different question — what the block says
      # — and ignores state and caret attributes on purpose.
      def changed?(block)
        @known.key?(block.id) && @known[block.id] != sent_digest(block)
      end

      def sent_digest(block)
        Digest::SHA256.hexdigest(block.html.to_s)[0, 16]
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000
      end

    # Default transport. Turbo Streams today; the seam is here so SSE is
    # possible without the broadcaster knowing about it.
    class TurboTransport
      def call(record:, frame:, config:)
        return unless defined?(Turbo::StreamsChannel)

        target = record.maquina_stream_target

        frame.appends.each do |block|
          Turbo::StreamsChannel.broadcast_append_to(
            target,
            target: "ms-msg-#{record.maquina_stream_id}",
            content: block.html,
            attributes: frame_attributes(frame, :append)
          )
        end

        frame.patch.each do |block|
          Turbo::StreamsChannel.broadcast_replace_to(
            target,
            target: block.id,
            content: block.html,
            attributes: frame_attributes(frame, :patch).merge("method" => "morph")
          )
        end
      end

      private
        def frame_attributes(frame, kind)
          {"data-ms-seq" => frame.seq, "data-ms-frame" => kind}
        end
    end
  end
end
