# frozen_string_literal: true

# The host side of the contract, and the only integration code there is: a
# model client hands over text, the broadcaster turns it into frames. No
# adapter, no service object, no engine-shaped abstraction in between.
class Message < ActiveRecord::Base
  include MaquinaStream::Streamable

  maquina_stream buffer: :content,
    stream_for: ->(m) { [:conversation, m.conversation_id, :messages] }

  # Every role streams through the same path. A tool call is a record of its
  # own — decided 2026-09-07 — so its output seals, repairs and exports exactly
  # like an assistant message, and the conversation is a list of streams rather
  # than one stream with structure hidden inside it.
  scope :assistant, -> { where(role: "assistant") }
  scope :tools, -> { where(role: "tool") }

  # Bare `ruby_llm`: ask, append what arrives, seal once.
  #
  # `broadcaster:` is a seam rather than a mock. A test hands it a recorder and
  # counts bytes; production leaves it alone and it broadcasts over Turbo.
  def stream_from(chat, prompt, broadcaster: MaquinaStream::Broadcaster.new(self))
    response = chat.ask(prompt) do |chunk|
      text = chunk.content.to_s
      broadcaster.append(text) unless text.empty?
    end

    # A provider that does not stream answers in one piece, and that is a real
    # arrival shape rather than a test artifact — it is what a batched Nexo step
    # looks like, measured at 1.28x the floor against 1.25x for token arrival.
    # `ruby_llm-test`'s provider is one of them, deliberately: it makes the
    # deterministic path exercise the shape the plan says to expect.
    text = response.respond_to?(:content) ? response.content.to_s : ""
    broadcaster.append(text) if maquina_stream_buffer.to_s.empty? && !text.empty?

    broadcaster.seal!
    response
  rescue
    # The seal is what makes drift cosmetic: a stream that ends without one
    # leaves every client waiting for a frame that is never coming.
    broadcaster.seal!(status: :errored)
    raise
  end
end
