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
  # ```ruby
  # MaquinaStream::Renderer.call(markdown, mode: :streaming) # => SafeBuffer
  # ```
  #
  # Pure: no request, no controller, no stubbing. The same function serves the
  # live stream, a page reload, a replay and an export, and `mode` changes
  # nothing but whether the reveal attributes are emitted. If this ever starts
  # needing request context, that is a design error rather than a plumbing one.
  #
  # ## The pipeline
  #
  # 1. `MaquinaRemend.call` repairs the unterminated markdown a half-written
  #    buffer always ends in — an open bold run, an unclosed fence.
  # 2. Commonmarker parses it, with source positions.
  # 3. Renderer::PostPass rewrites elements: fences, custom tags, registered
  #    element overrides, text direction, block indices.
  # 4. Sanitizer runs, unconditionally, last.
  #
  # Renderer returns one HTML string for the whole buffer. It does **not**
  # split it into blocks or stamp ids and digests on them — that is Document,
  # and without it a page cannot be repaired at all. Host code almost always
  # wants MaquinaStream.render or Document rather than this.
  class Renderer
    # The two render modes. Both produce the same document byte for byte; the
    # mode is carried so the post-pass knows whether the message is still being
    # written.
    MODES = %i[streaming static].freeze

    # unsafe: true lets registered custom tags through the parser. It is not a
    # relaxation: the sanitizer is the gate, it runs unconditionally, and it runs
    # last. Model output is assumed hostile at every step before it.
    COMMONMARKER_OPTIONS = {
      parse: {sourcepos_chars: true},
      render: {sourcepos: true, unsafe: true, github_pre_lang: false},
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
    COMMONMARKER_PLUGINS = {syntax_highlighter: nil}.freeze

    # The mode this renderer was built with, one of MODES.
    attr_reader :mode

    # The Configuration this renderer reads.
    attr_reader :config

    # Renders `markdown` in one call. The usual entry point.
    #
    # `mode:` is `:streaming` or `:static`; anything else raises ArgumentError.
    # `config:` defaults to the global MaquinaStream.config, and is a keyword
    # rather than a lookup so the renderer stays callable from a plain Ruby
    # process with no Rails around it.
    def self.call(markdown, mode: :streaming, config: MaquinaStream.config)
      new(mode: mode, config: config).call(markdown)
    end

    # Builds a reusable renderer. Raises ArgumentError unless `mode:` is one of
    # MODES.
    def initialize(mode: :streaming, config: MaquinaStream.config)
      raise ArgumentError, "mode must be one of #{MODES.join(", ")}" unless MODES.include?(mode)

      @mode = mode
      @config = config
    end

    # Renders one markdown string to sanitized HTML.
    #
    # Returns an `html_safe` String — a plain String when ActiveSupport is not
    # loaded — and an empty one for nil or whitespace-only input.
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
