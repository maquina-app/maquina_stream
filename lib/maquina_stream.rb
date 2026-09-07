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

module MaquinaStream
  extend Registries

  # Components destined for maquina_components, vendored inside the engine for
  # now. See docs/component-scope.md.
  VENDORED_COMPONENTS = %i[attachment code_block suggestion snippet].freeze

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def reset_configuration!
      @config = Configuration.new
    end

    # Render a message, cached once it is sealed.
    #
    #   <%= MaquinaStream.render(message) %>
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
