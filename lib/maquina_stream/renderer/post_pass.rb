# frozen_string_literal: true

module MaquinaStream
  class Renderer
    # One walk over the parsed document. Everything that needs the tree happens
    # here: fence strategies, table wrappers, element hooks, registered custom
    # tags, and the reveal attributes that separate streaming from static.
    #
    # It is one pass on purpose. Each extra traversal is paid on every frame of
    # every message.
    class PostPass
      ELEMENT_HOOKS = %w[h1 h2 h3 h4 h5 h6 p ul ol li table blockquote pre hr img a].freeze
      ELEMENT_HOOK_SET = ELEMENT_HOOKS.to_set.freeze

      attr_reader :fragment, :markdown, :mode, :config

      def initialize(fragment, markdown:, mode:, config:)
        @fragment = fragment
        @markdown = markdown
        @mode = mode
        @config = config
      end

      def call
        collect

        rewrite_fences
        wrap_tables
        render_registered_tags
        apply_overrides
        annotate_reveal if streaming?
        annotate_blocks
        fragment
      end

      private
        attr_reader :tables, :tagged, :overrides

        def streaming? = mode == :streaming

        # The single walk this class has always claimed to be.
        #
        # Every CSS query over a 2,000-node document costs about 3.5ms, and this
        # runs on every frame of every message: five queries were most of the
        # frame. Attribute work happens inline because it cannot restructure the
        # tree; anything that replaces a node is collected and applied after the
        # walk, because replacing a node mid-traversal makes the walk skip
        # siblings.
        def collect
          @code_blocks = []
          @tables = []
          @tagged = Hash.new { |hash, key| hash[key] = [] }
          @overrides = []
          registered = MaquinaStream.tags.keys.to_set

          fragment.traverse do |node|
            next unless node.element?

            node.remove_attribute("data-sourcepos") if node.attribute("data-sourcepos")

            name = node.name

            if ELEMENT_HOOK_SET.include?(name)
              node["data-ms-element"] = name
              @overrides << node if MaquinaStream.elements.key?(name.to_sym)
            end

            case name
            when "pre" then @code_blocks << node if node.at_css("> code")
            when "table" then @tables << node
            end

            @tagged[name.to_sym] << node if registered.include?(name.to_sym)
          end
        end

        # The open fence, when there is one, is the last one in the document:
        # the buffer can only be cut in one place.
        def open_fence_index
          return @open_fence_index if defined?(@open_fence_index)

          open = MaquinaRemend.context(markdown).in_code_fence?
          @open_fence_index = open ? code_blocks.length - 1 : nil
        end

        attr_reader :code_blocks

        def rewrite_fences
          code_blocks.each_with_index do |pre, index|
            code = pre.at_css("code")
            fence = Fence.new(
              info: language_of(code),
              source: code.text,
              open: index == open_fence_index,
              config: config
            )

            replacement = render_fence(fence)
            pre.replace(replacement) if replacement
          end
        end

        def render_fence(fence)
          case fence.strategy
          when :client then render_client_fence(fence)
          when :passthrough then nil
          else render_server_fence(fence)
          end
        end

        # Cached on the locals, which is what the partial is a pure function of.
        # A fence that closed twenty frames ago renders identically on every
        # frame after it, and rendering it again is most of a frame's cost.
        def render_server_fence(fence)
          partial = Components.partial_for(:code_block, config: config)

          # An open fence gets no controls. They would be inert anyway — copying
          # half a code block is worse than not offering to — and the open block
          # is re-sent on every frame, so its chrome is paid for over and over.
          controls = fence.open? ? {} : config.controls[:code]

          ComponentCache.fetch(partial, fence.language, fence.open?, controls, fence.source) do
            view.render(
              partial,
              lang: fence.language,
              source: fence.source,
              highlighted: html_safe(fence.highlighted),
              open: fence.open?,
              controls: controls
            )
          end
        end

        # Rouge emits markup and escapes the source itself, so it is passed to
        # the partial as markup rather than as text. It is not an exception to
        # "never assign model output as raw HTML": the sanitizer still runs over
        # the whole document afterwards, and it is the gate.
        def html_safe(html)
          html.respond_to?(:html_safe) ? html.html_safe : html
        end

        # Skeleton until the fence closes, then payload and controller. The
        # skeleton is the shimmer component; there is no ad-hoc placeholder
        # markup anywhere in the engine.
        def render_client_fence(fence)
          return render_shimmer(fence) if fence.open?

          node = Nokogiri::XML::Node.new("div", fragment.document)
          node["data-controller"] = fence.controller if fence.controller
          node["data-#{fence.controller}-payload-value"] = payload_json(fence) if fence.controller

          # Split ownership, per the DOM contract: the payload attribute is
          # server state and belongs to morph, the output element is client
          # state and belongs to the controller. The skeleton sits inside the
          # output element so the controller replaces it when it renders.
          #
          # The stable id (ms-<sid>-b<n>-out) needs the message id, which a pure
          # renderer does not have. Phase 3 stamps it along with the block ids,
          # and data-turbo-permanent only takes effect once it is there.
          output = Nokogiri::XML::Node.new("div", fragment.document)
          output["data-#{fence.controller}-target"] = "output" if fence.controller
          output["data-turbo-permanent"] = ""
          output.inner_html = render_shimmer(fence)

          node.add_child(output)
          node.to_html
        end

        # The one skeleton, resolved through the seam like every other
        # component. Nothing here names a partial path.
        def render_shimmer(fence)
          partial = Components.partial_for(:shimmer, config: config)

          ComponentCache.fetch(partial, fence.language) do
            view.render(partial, label: fence.language)
          end
        end

        # The HTML5 serializer escapes only &, " and NBSP inside an attribute
        # value, so a fence containing "</div><script>" would sit in the payload
        # with its angle brackets intact. It does not break out of the attribute,
        # but it does mean the raw string is in the document; escaping at the
        # JSON level keeps the payload inert whatever reads it next.
        def payload_json(fence)
          JSON.generate(fence.payload).gsub("<", "\\u003c").gsub(">", "\\u003e")
        end

        def language_of(code)
          code["class"].to_s[/language-(\S+)/, 1].to_s
        end

        def wrap_tables
          controls = config.controls[:table] || {}
          interactive = controls.values.any?

          tables.each do |table|
            wrapper = Nokogiri::XML::Node.new("div", fragment.document)
            wrapper["data-ms-table"] = ""
            wrapper["data-controller"] = "ms-table" if interactive
            table.replace(wrapper)
            wrapper.add_child(table_controls(controls)) if interactive
            wrapper.add_child(table)
            table["data-ms-table-target"] = "table" if interactive
          end
        end

        # The ms-table controller documents the markup it expects and emits none
        # of it itself. This is engine chrome rather than a component: there is
        # no table entry in docs/component-scope.md, and inventing one to hold
        # three buttons would be worse than drawing them here.
        def table_controls(controls)
          bar = Nokogiri::XML::Node.new("div", fragment.document)
          bar["data-ms-table-part"] = "controls"

          if controls[:copy]
            table_button(bar, "copy", "markdown", :copy_markdown)
            table_button(bar, "copy", "csv", :copy_csv)
          end
          table_button(bar, "download", "csv", :download_csv) if controls[:download]
          table_button(bar, "toggleFullscreen", nil, :fullscreen) if controls[:fullscreen]

          bar
        end

        def table_button(bar, action, format, key)
          node = Nokogiri::XML::Node.new("button", fragment.document)
          node["type"] = "button"
          node["data-action"] = "ms-table##{action}"
          node["data-ms-table-format-param"] = format if format
          label = I18n.t("maquina_stream.table.#{key}", locale: locale, default: key.to_s.tr("_", " "))
          node["aria-label"] = label
          node.content = label
          bar.add_child(node)
        end

        # The host owns the locale, as in any Rails app: labels follow
        # I18n.locale. `config.locale` is the engine's own default, used when
        # the host has expressed no preference — see docs/interaction.md.
        def locale
          I18n.locale || config.locale
        end

        # A registered tag is rendered through its partial with only the
        # attributes its registration allows. An unregistered tag is left for the
        # sanitizer, which drops it.
        def render_registered_tags
          MaquinaStream.tags.each do |name, tag|
            tagged[name].each do |node|
              allowed = Array(tag.options[:attributes]).to_h { |key| [key.to_sym, node[key]] }
              content = tag.options[:literal_content] ? node.text : node.inner_html

              node.replace(view.render(tag.options[:partial], **allowed, content: content))
            end
          end
        end

        # One traversal, not one CSS query per element type. Eighteen queries
        # over a 2,000-node document cost 31ms of a 68ms frame; walking it once
        # costs a fraction of that, and this runs on every frame of every
        # message.
        #
        # Overrides are collected first and applied afterwards: replacing a node
        # while traversing the tree it is being read from is how a walk starts
        # skipping siblings.
        def apply_overrides
          overrides.each { |node| apply_element_override(node.name, node) }
        end

        def apply_element_override(name, node)
          registration = MaquinaStream.elements[name.to_sym]
          return unless registration&.options&.key?(:partial)

          node.replace(view.render(registration.options[:partial], content: node.inner_html, node: node))
        end

        # Top-level children are blocks. Numbering them here - rather than
        # letting Phase 3 match by position - means the splitter survives the
        # sanitizer dropping an element, which position matching would not.
        # The index is derived from order, never from content.
        def annotate_blocks
          fragment.children.select(&:element?).each_with_index do |node, index|
            node["data-ms-block-index"] = index.to_s
          end
        end

        # The only difference between streaming and static output. The parity
        # test strips these and demands the rest be byte-identical.
        #
        # The caret marks the block still being written. Static output has none,
        # which is what removes it at seal: the sealed message renders in static
        # mode, the tail's HTML changes, and the final frame carries that change.
        def annotate_reveal
          elements = fragment.children.select(&:element?)
          elements.each { |node| node["data-ms-reveal"] = "" }
          elements.last&.[]=("data-ms-caret", "")
        end

        def view
          @view ||= ViewContext.build
        end
    end
  end
end
