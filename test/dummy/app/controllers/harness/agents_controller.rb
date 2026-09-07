# frozen_string_literal: true

module Harness
  # nexo_ai: an agent run, streamed as several records. Each tool call opens a
  # record of its own and seals on its own — shape A, decided 2026-09-07, see
  # docs/streaming.md.
  #
  # The `broadcaster:` seam is what makes that visible in a browser. It is
  # called once per record the run opens, which is the only moment the host can
  # know a new stream exists, so the shell goes out there rather than from a
  # model callback that would also fire in every unit test.
  class AgentsController < LiveController
    CONVERSATION_ID = 102

    private

    def conversation_id = CONVERSATION_ID

    def run(prompt)
      Timeout.timeout(Llm::DEADLINE) do
        Message.stream_agent_run(@llm.agent, prompt, conversation_id: conversation_id, broadcaster: method(:open_stream))
      end
    end

    def open_stream(record)
      record.broadcast_shell
      MaquinaStream::Broadcaster.new(record)
    end
  end
end
