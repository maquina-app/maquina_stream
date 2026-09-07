# frozen_string_literal: true

require "json"
require "commonmarker"
require "nokogiri"
require "maquina_remend"

require_relative "renderer/view_context"
require_relative "renderer/fence"
require_relative "renderer/post_pass"

module MaquinaStream
  # Markdown in, sanitized HTML out.
  #
  #   MaquinaStream::Renderer.call(markdown, mode: :streaming)
  #
  # Pure: no request, no controller, no stubbing. The same function serves the
  # live stream, a page reload, a replay and an export, and +mode+ changes
  # nothing but whether the reveal attributes are emitted. If this ever starts
  # needing request context, that is a design error rather than a plumbing one.
  class Renderer
    MODES = %i[streaming static].freeze

    # unsafe: true lets registered custom tags through the parser. It is not a
    # relaxation: the sanitizer is the gate, it runs unconditionally, and it runs
    # last. Model output is assumed hostile at every step before it.
    COMMONMARKER_OPTIONS = {
      parse: { sourcepos_chars: true },
      render: { sourcepos: true, unsafe: true, github_pre_lang: false },
      extension: {
        table: true,
        strikethrough: true,
        autolink: true,
        tasklist: true,
        footnotes: true
      }
    }.freeze

    # commonmarker highlights with syntect by default, which would ship a second
    # highlighter's inline styles into a pipeline that already owns highlighting
    # (Rouge, at fence close only) and forbids inline colour. Confirmed against
    # commonmarker 2.10.0 in test/sourcepos_test.rb.
    COMMONMARKER_PLUGINS = { syntax_highlighter: nil }.freeze

    attr_reader :mode, :config

    def self.call(markdown, mode: :streaming, config: MaquinaStream.config)
      new(mode: mode, config: config).call(markdown)
    end

    def initialize(mode: :streaming, config: MaquinaStream.config)
      raise ArgumentError, "mode must be one of #{MODES.join(", ")}" unless MODES.include?(mode)

      @mode = mode
      @config = config
    end

    def call(markdown)
      return safe("") if markdown.nil? || markdown.strip.empty?

      repaired = MaquinaRemend.call(markdown)
      parsed = Commonmarker.to_html(repaired, options: COMMONMARKER_OPTIONS, plugins: COMMONMARKER_PLUGINS)
      fragment = Nokogiri::HTML5.fragment(parsed)

      PostPass.new(fragment, markdown: repaired, mode: mode, config: config).call

      safe(Sanitizer.call(fragment.to_html, config: config))
    end

    private
      # ActiveSupport is present inside the engine, but the renderer is expected
      # to run in a plain process too, so the wrapper degrades to a String.
      def safe(html)
        html.respond_to?(:html_safe) ? html.html_safe : html
      end
  end
end
