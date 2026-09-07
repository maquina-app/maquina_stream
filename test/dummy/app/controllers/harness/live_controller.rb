# frozen_string_literal: true

module Harness
  # The two live pages, which are the same page twice: a prompt goes to a real
  # endpoint, the engine turns what comes back into frames, and the browser is
  # told over Turbo Streams. Only `#run` differs — bare ruby_llm on one,
  # nexo_ai on the other.
  #
  # Everything here is orchestration. The streaming, the sealing and the
  # broadcasting all live on Message, because that is the record that owns them.
  class LiveController < ActionController::Base
    layout "application"

    before_action { @llm = Llm.load }

    def show
      @messages = conversation.order(:id)
    end

    # Streamed inside the request rather than in a job, because a job needs a
    # queue and the point of this page is the engine, not the queue. The request
    # thread comes back at Llm::DEADLINE whatever the model is doing, and the
    # `ensure` is what guarantees every record ends sealed — an open record is a
    # client waiting for a frame that never arrives.
    def create
      prompt = params[:prompt].to_s.strip
      run(prompt).each(&:broadcast_shell) if prompt.present? && @llm.configured?
    rescue => error
      # The class and the message, with the key removed from both. Nothing about
      # the failure is logged with credentials in it.
      flash[:alert] = @llm.scrub("#{error.class}: #{error.message}")
    ensure
      Message.seal_abandoned!(conversation_id: conversation_id)
      redirect_to url_for(action: :show), status: :see_other
    end

    def destroy
      conversation.delete_all
      redirect_to url_for(action: :show), status: :see_other
    end

    private

    def conversation
      Message.where(conversation_id: conversation_id)
    end
  end
end
