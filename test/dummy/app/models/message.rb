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

  # A Nexo agent run, streamed as several records rather than one.
  #
  # Nexo reports tool activity through the block `Agent#prompt` takes, as
  # `(type, payload)`. Each `:tool_call` opens a record of its own; the
  # assistant's answer is a record of its own too. That is the decision, made
  # concrete: two streams can be open at once — which is what a parallel tool
  # call IS — and a tool's output seals, repairs and exports without the
  # assistant's message having to be re-rendered around it.
  #
  # Holding them in one record would mean the opposite: a tool result arriving
  # late rewrites blocks in the middle of a message whose tail has moved on,
  # which is exactly the case the seal lag cannot cover.
  def self.stream_agent_run(agent, prompt, conversation_id:, broadcaster: nil)
    build = ->(message) { broadcaster ? broadcaster.call(message) : MaquinaStream::Broadcaster.new(message) }
    open = {}
    records = []

    response = agent.prompt(prompt) do |type, payload|
      case type
      when :tool_call
        name = tool_name_of(payload)
        record = create!(conversation_id: conversation_id, role: "tool", tool_name: name)
        records << record
        open[name] = build.call(record)
        open[name].append("**#{name}**\n\n```json\n#{arguments_of(payload)}\n```\n")
      when :tool_result
        # Results can arrive for a tool that was never announced — a cached
        # call, or a backend that reports only completions. Opening the record
        # here keeps the stream honest rather than dropping the output.
        name = tool_name_of(payload) || open.keys.last
        stream = open[name] ||= build.call(create!(conversation_id: conversation_id, role: "tool", tool_name: name).tap { |r| records << r })
        stream.append("\n```\n#{content_of(payload)}\n```\n")
        stream.seal!
        open.delete(name)
      end
    end

    answer = create!(conversation_id: conversation_id, role: "assistant")
    records << answer
    stream = build.call(answer)
    stream.append(content_of(response))
    stream.seal!

    # Anything still open ended without a result: seal it, or every client
    # waits for a frame that is never coming.
    open.each_value { |unfinished| unfinished.seal!(status: :errored) }

    records
  end

  # Nexo hands the block whatever ruby_llm's tool-call object is, and a Hash
  # from some backends. Ask for the name the way each shape answers.
  def self.tool_name_of(payload)
    %i[name tool_name tool].each do |key|
      value = if payload.respond_to?(key)
        payload.public_send(key)
      elsif payload.is_a?(Hash)
        payload[key]
      end

      return value.to_s if value.present?
    end

    nil
  end

  def self.arguments_of(payload)
    value = payload.respond_to?(:arguments) ? payload.arguments : nil
    (value || {}).to_json
  end

  def self.content_of(payload)
    return payload.to_s unless payload.respond_to?(:content)
    payload.content.to_s
  end

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
