# frozen_string_literal: true

require "nexo"

# The agent behind `/harness/agent`.
#
# Everything except the model name is fixed here, because everything except the
# model name is a safety decision rather than a setting. The sandbox is
# `:virtual` — an in-memory Hash with zero host access — so `:auto` permissions
# cost nothing: the model may write files, and the files are a Ruby Hash that
# dies with the request. A `:local` sandbox with the same permissions would be
# handing an endpoint on the far side of the network a shell on this machine.
#
# The model name is passed per instance (`HarnessAgent.new(model:)`) rather than
# declared with the class macro, so nothing reads `config/llm.yml` at boot.
class HarnessAgent < Nexo::Agent
  provider :openai
  assume_model_exists true
  sandbox :virtual
  permissions :auto

  # Markdown, deliberately: the whole point of the page is that what a model
  # writes is rendered through the engine rather than printed.
  instructions <<~TEXT
    You are a terse assistant with file tools that act on an in-memory
    workspace at /workspace. Use them when the request calls for it. Answer in
    markdown, using headings, lists, tables and fenced code blocks where they
    fit. Keep answers under 200 words.
  TEXT
end
