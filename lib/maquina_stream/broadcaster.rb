# frozen_string_literal: true

require "digest"

module MaquinaStream
  # Turns a growing buffer into a stream of small patches.
  #
  # ```ruby
  # broadcaster = MaquinaStream::Broadcaster.new(message)
  # model.stream { |token| broadcaster.append(token) }
  # broadcaster.seal!                 # final frame, always
  # ```
  #
  # It remembers what the browser already has — block id to digest — and sends
  # only what moved. A block that has not changed is never re-sent, which is the
  # difference between bandwidth tracking drift and bandwidth tracking message
  # length.
  #
  # Transport is a seam. It defaults to Turbo Streams over whatever cable the
  # host configured, and a test can hand it a recorder instead; that recorder is
  # how the bandwidth budget is asserted rather than estimated.
  #
  # One broadcaster per stream, held for the life of that stream: what the
  # browser already has lives in the instance, so a fresh broadcaster mid-stream
  # re-sends every block. It is not thread-safe; drive one stream from one
  # place.
  #
  # **Deltas do not converge on their own, and are not meant to.** Only the open
  # tail is patched; a block that changes after it stops being the tail is fixed
  # by the repair path. Correctness lives there.
  class Broadcaster
    # The host record being streamed. Must satisfy MaquinaStream::Streamable.
    attr_reader :record

    # The Configuration this broadcaster reads — `frame_budget_ms` and
    # `seal_lag` in particular.
    attr_reader :config

    # The object frames are emitted through. Responds to
    # `call(record:, frame:, config:)`.
    attr_reader :transport

    # Builds a broadcaster over one record.
    #
    # `transport:` defaults to TurboTransport. It is a seam: anything answering
    # `call(record:, frame:, config:)` will do, which is how the bandwidth
    # budget is asserted against a recorder rather than estimated.
    def initialize(record, config: MaquinaStream.config, transport: nil)
      @record = record
      @config = config
      @transport = transport || TurboTransport.new
      @known = {}
      @tail_id = nil
      @last_flush = nil
    end

    # Appends `text` to the record's buffer and broadcasts if the frame budget
    # has elapsed. Returns the Frame that went out, or nil when this append was
    # coalesced into the next one.
    #
    # This is the method a streaming loop calls, once per token or per chunk.
    #
    # Host owns persistence: it appends to its own column, and only then is
    # there anything to broadcast.
    def append(text, now: monotonic_ms)
      record.maquina_stream_append(text)
      broadcast(now: now)
    end

    # Seals the record and emits the final frame. Returns that Frame.
    #
    # `status:` is one of Streamable::SEAL_STATUSES. Call this exactly once,
    # including when a stream failed: an errored message still has text worth
    # keeping, and the client has no other way to learn the stream is over.
    #
    # The final frame is never coalesced and never skipped. Every intra-stream
    # drift becomes cosmetic and self-correcting because of this one.
    def seal!(status: :complete)
      record.maquina_stream_seal!(status: status)
      emit(now: monotonic_ms, final: true)
    end

    # Broadcasts a frame if the budget has elapsed, without appending
    # anything. Returns the Frame or nil.
    #
    # Useful when the buffer moved by some other route — a host that writes to
    # the column itself and wants the browser told about it.
    #
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

    # A Document over the record's current buffer, rendered in the mode its
    # status implies. Rebuilt on every call, because the buffer moves.
    #
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

      def emit(now:, final: false)
        frame = build_frame
        return nil if frame.empty? && !final

        @last_flush = now
        frame.blocks.each { |block| @known[block.id] = sent_digest(block) }

        # The sequence belongs to the host's row and moves once per frame that
        # actually goes out, not once per append.
        sequenced = Frame.new(
          seq: record.maquina_stream_advance,
          appends: frame.appends,
          patch: frame.patch,
          final: final
        )
        transport.call(record: record, frame: sequenced, config: config)
        sequenced
      end

      # Append what the browser has never seen; patch the open tail, and nothing
      # else.
      #
      # A block often takes its final form in the very frame that opens the one
      # below it — a heading completes as the paragraph after it begins — and so
      # stops being the tail while the client still holds "Status rep".
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
    #
    # Appends go out as `broadcast_append_to` against the message element;
    # patches as `broadcast_replace_to` with `method: "morph"`, so idiomorph
    # pairs the node by id instead of recreating it. Every stream action carries
    # `data-ms-seq` and `data-ms-frame`.
    #
    # A no-op when Turbo is not loaded, so the engine's Ruby side stays usable
    # without it.
    class TurboTransport
      # Emits one Frame. The transport contract is this method and nothing
      # else.
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
        # The final seal is marked as such, whatever it happens to carry. The
        # repair path triggers on it.
        def frame_attributes(frame, kind)
          {"data-ms-seq" => frame.seq, "data-ms-frame" => frame.final? ? :final : kind}
        end
    end
  end
end
