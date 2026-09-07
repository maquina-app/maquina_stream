# frozen_string_literal: true

require "maquina_stream/version"
require "maquina_stream/errors"
require "maquina_stream/configuration"
require "maquina_stream/registries"
require "maquina_stream/streamable"
require "maquina_stream/renderer"
require "maquina_stream/document"
require "maquina_stream/block"
require "maquina_stream/broadcaster"
require "maquina_stream/frame"
require "maquina_stream/manifest"
require "maquina_stream/sanitizer"
require "maquina_stream/text_direction"
require "maquina_stream/themes"
require "maquina_stream/export"
require "maquina_stream/component_cache"
require "maquina_stream/components"
require "maquina_stream/components/contract"
require "maquina_stream/engine" if defined?(Rails::Engine)

# Server-rendered streaming markdown for Rails, over Turbo, with a repair path.
#
# A model writes markdown a token at a time. The engine renders it on the
# server, broadcasts small patches as it grows, and reconciles the browser with
# the truth when frames go missing — which they do, because Action Cable offers
# no delivery guarantee. **Only rendered HTML reaches the browser**; the client
# never parses markdown.
#
# ## The whole integration
#
# ```ruby
# class Message < ApplicationRecord
#   include MaquinaStream::Streamable
#
#   maquina_stream buffer: :content,
#                  stream_for: ->(m) { [m.conversation, :messages] }
# end
#
# broadcaster = MaquinaStream::Broadcaster.new(message)
# model.stream { |token| broadcaster.append(token) }
# broadcaster.seal!
# ```
#
# ```erb
# <%= MaquinaStream.render(message) %>
# ```
#
# ## What a host owns
#
# The engine resolves nothing and authorizes nothing on its own. Three things
# are the host's, and none of them has a default the engine could guess:
#
# | Host responsibility | Where it goes |
# |---|---|
# | Looking a record up by its stream id | Configuration#find_stream |
# | Deciding whether a request may see it | Configuration#authorize |
# | Persisting the buffer, sequence and status | MaquinaStream::Streamable |
#
# **With no `authorize` configured, every repair request is refused.** That is
# deliberate: an engine that guesses is an engine that leaks.
#
# ## Where to look next
#
# | Object | Responsibility |
# |---|---|
# | MaquinaStream::Configuration | Every option, its default and what changing it costs |
# | MaquinaStream::Streamable | The host contract, and the macro that generates it |
# | MaquinaStream::Broadcaster | Frame coalescing and Turbo Stream emission |
# | MaquinaStream::Renderer | Markdown in, sanitized HTML out. A pure function |
# | MaquinaStream::Document | Splits a rendered message into blocks and decides which may freeze |
# | MaquinaStream::Block | One top-level block: id, markdown, HTML, digest |
# | MaquinaStream::Frame | One broadcast: what changed since the last one |
# | MaquinaStream::Manifest | What the browser is told the message currently is |
# | MaquinaStream::Sanitizer | Allowlist plus URL hardening, the last pass before output |
# | MaquinaStream::Export | A whole message, back out as markdown |
# | MaquinaStream::TextDirection | Which way a piece of text reads |
# | MaquinaStream::Components::Contract | The engine's half of a vendored component |
#
# Longer-form documentation ships in `docs/`: `getting-started.md`,
# `configuration.md`, `streaming.md`, `repair.md`, `registries.md`,
# `javascript.md`, `security.md` and `deferred-renderers.md`.
module MaquinaStream
  extend Registries

  # Components destined for maquina_components, vendored inside the engine for
  # now. Everything renders through MaquinaStream::Components, so extraction is
  # a matter of publishing the partial there and dropping the name from here.
  VENDORED_COMPONENTS = %i[attachment code_block suggestion snippet].freeze

  class << self
    # The current Configuration. Memoized; the same object `configure`
    # yields.
    def config
      @config ||= Configuration.new
    end

    # Configures the engine. Yields the Configuration and returns it.
    #
    # ```ruby
    # MaquinaStream.configure do |c|
    #   c.find_stream = ->(sid) { Message.find_by(id: sid) }
    #   c.authorize   = ->(record, request) { record.conversation.readable_by?(request) }
    # end
    # ```
    #
    # Every option, with its default and the consequence of changing it, is
    # documented on Configuration. Call this once from an initializer:
    # configuration is global and read on every render, so changing it
    # mid-stream changes what later frames of an open message look like.
    def configure
      yield config
      config
    end

    # Throws away the configuration and starts again from the defaults.
    #
    # For tests. A host that calls this in production loses its `find_stream`
    # and `authorize` seams, and every repair request after it is refused.
    def reset_configuration!
      @config = Configuration.new
    end

    # Renders a whole message to HTML, cached once it is sealed. Returns an
    # `html_safe` String.
    #
    # ```erb
    # <%= MaquinaStream.render(message) %>
    # ```
    #
    # This is the history path — one call, one finished message on a page. It
    # is not what a live stream uses: an open stream goes out frame by frame
    # through Broadcaster. Pagination stays the host's; the engine renders the
    # messages the host chose, in the order it chose them.
    #
    # `record` must satisfy MaquinaStream::Streamable. `config:` defaults to
    # the global MaquinaStream.config.
    #
    # A sealed message is immutable, so its HTML is a pure function of its
    # buffer and can be cached by digest — which is what makes a page of history
    # cheap: re-rendering fifty finished messages on every page load is work
    # nobody asked for. An open message is never cached; it is about to change.
    #
    # The digest is of the buffer, so a host that edits a message gets a new key
    # rather than a stale render.
    def render(record, config: self.config)
      markdown = record.maquina_stream_buffer

      # Through Document, not Renderer. Renderer produces the HTML; Document is
      # what stamps each block with the id and digest the DOM contract requires,
      # and without those a page cannot be repaired at all — ms-repair would
      # have nothing to compare a manifest against.
      return document_html(record, markdown, config) if record.maquina_stream_open?

      ComponentCache.fetch("document", record.maquina_stream_id, Digest::SHA256.hexdigest(markdown.to_s)) do
        document_html(record, markdown, config)
      end
    end

    private

    def document_html(record, markdown, config)
      blocks = Document.new(
        markdown,
        config: config,
        sid: record.maquina_stream_id,
        mode: record.maquina_stream_open? ? :streaming : :static
      ).blocks

      html = blocks.map(&:html).join("\n")
      html.respond_to?(:html_safe) ? html.html_safe : html
    end
  end
end
