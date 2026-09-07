# frozen_string_literal: true

require "yaml"
require "ruby_llm"

# The harness's live model settings, read from `test/dummy/config/llm.yml` — a
# file the reader writes and git ignores. `config/llm.yml.example` documents it.
#
# This is the only place the three settings come from. No ENV fallback and no
# default host: a harness that quietly falls back to somebody else's endpoint is
# a harness that cannot tell "not configured" from "the model is down", and
# those are the two failures a live page exists to distinguish.
#
#   Llm.load.configured?   # false when the file is missing or half-written
#   Llm.load.chat          # RubyLLM::Chat        — /harness/chat
#   Llm.load.agent         # HarnessAgent         — /harness/agent
#
# The key is read here and nowhere else. It is never logged, never rendered and
# never returned: `#url` and `#model` are readers, `#key` is private.
class Llm
  PATH = "config/llm.yml"
  EXAMPLE = "config/llm.yml.example"

  # A model that never stops still has to give the request thread back. Past
  # this the stream is abandoned and the message seals as `errored`, which is
  # the frame every client is waiting for — see `Message#stream_from`.
  DEADLINE = 90

  attr_reader :url, :model

  def self.load
    new(**settings)
  end

  # A file that is missing, unreadable or not a mapping is the same answer: no
  # settings. Raising here would turn "you have not set this up yet" into a 500.
  def self.settings
    file = YAML.safe_load_file(Rails.root.join(PATH))
    file.is_a?(Hash) ? file.symbolize_keys.slice(:url, :key, :model) : {}
  rescue SystemCallError, Psych::Exception
    {}
  end

  def initialize(url: nil, key: nil, model: nil)
    @url = url.to_s.strip
    @key = key.to_s.strip
    @model = model.to_s.strip
  end

  def configured?
    url.present? && model.present?
  end

  # Bare ruby_llm. `assume_model_exists` skips the models.json registry lookup,
  # which no local ollama tag is listed in, and `provider: :openai` names the
  # wire format rather than the vendor.
  def chat
    configure!
    RubyLLM.chat(model: model, provider: :openai, assume_model_exists: true)
  end

  # The same endpoint, driven through Nexo instead. `HarnessAgent` carries the
  # sandbox, the permissions and the instructions; only the model name is a
  # setting, and it is per-instance so nothing is read at boot.
  def agent
    configure!
    HarnessAgent.new(model: model)
  end

  # Failures quote request context. The key is never part of a URL and never
  # part of an error this code raises, but an endpoint that echoes a header back
  # would put it in one — so it is removed from anything a page shows.
  def scrub(text)
    key.present? ? text.to_s.gsub(key, "[redacted]") : text.to_s
  end

  private

  attr_reader :key

  # Global rather than a per-call context, because Nexo builds its own
  # `RubyLLM.chat` and there is no context to hand it. One code path for both
  # pages is worth more here than the isolation, in an app that talks to exactly
  # one endpoint.
  def configure!
    RubyLLM.configure do |c|
      c.openai_api_base = url
      # ollama wants no key; ruby_llm wants a non-empty string.
      c.openai_api_key = key.presence || "no-key"
    end
  end
end
