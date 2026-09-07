# frozen_string_literal: true

module Harness
  # Bare ruby_llm: `chat.ask` with a block, every chunk appended, one seal.
  # There is no adapter and no agent framework between the model and the
  # engine — `Message#stream_from` is the whole integration.
  class ChatsController < LiveController
    CONVERSATION_ID = 101

    private

    def conversation_id = CONVERSATION_ID

    def run(prompt)
      message = Message.create!(conversation_id: conversation_id, role: "assistant")
      message.broadcast_shell

      Timeout.timeout(Llm::DEADLINE) { message.stream_from(@llm.chat, prompt) }

      [message]
    end
  end
end
