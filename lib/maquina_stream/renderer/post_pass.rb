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

      attr_reader :fragment, :markdown, :mode, :config

      def initialize(fragment, markdown:, mode:, config:)
        @fragment = fragment
        @markdown = markdown
        @mode = mode
        @config = config
      end

      def call
        rewrite_fences
        wrap_tables
        render_registered_tags
        annotate_elements
        annotate_blocks
        strip_sourcepos
        fragment
      end

      private
        def streaming? = mode == :streaming

        # The open fence, when there is one, is the last one in the document:
        # the buffer can only be cut in one place.
        def open_fence_index
          return @open_fence_index if defined?(@open_fence_index)

          open = MaquinaRemend.context(markdown).in_code_fence?
          @open_fence_index = open ? code_blocks.length - 1 : nil
        end

        def code_blocks
          @code_blocks ||= fragment.css("pre > code").map(&:parent)
        end

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

        def render_server_fence(fence)
          view.render(
            Components.partial_for(:code_block, config: config),
            lang: fence.language,
            source: fence.source,
            highlighted: html_safe(fence.highlighted),
            open: fence.open?,
            controls: config.controls[:code]
          )
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
          node.inner_html = render_shimmer(fence)
          node.to_html
        end

        # The one skeleton, resolved through the seam like every other
        # component. Nothing here names a partial path.
        def render_shimmer(fence)
          view.render(Components.partial_for(:shimmer, config: config), label: fence.language)
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
          fragment.css("table").each do |table|
            wrapper = Nokogiri::XML::Node.new("div", fragment.document)
            wrapper["data-ms-table"] = ""
            wrapper["data-controller"] = "ms-table" if config.controls.dig(:table, :copy)
            table.replace(wrapper)
            wrapper.add_child(table)
          end
        end

        # A registered tag is rendered through its partial with only the
        # attributes its registration allows. An unregistered tag is left for the
        # sanitizer, which drops it.
        def render_registered_tags
          MaquinaStream.tags.each do |name, tag|
            fragment.css(name.to_s).each do |node|
              allowed = Array(tag.options[:attributes]).to_h { |key| [key.to_sym, node[key]] }
              content = tag.options[:literal_content] ? node.text : node.inner_html

              node.replace(view.render(tag.options[:partial], **allowed, content: content))
            end
          end
        end

        def annotate_elements
          ELEMENT_HOOKS.each do |name|
            fragment.css(name).each do |node|
              node["data-ms-element"] = name
              apply_element_override(name, node)
            end
          end

          annotate_reveal if streaming?
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
        def annotate_reveal
          fragment.children.each do |node|
            node["data-ms-reveal"] = "" if node.element?
          end
        end

        def strip_sourcepos
          fragment.css("[data-sourcepos]").each { |node| node.remove_attribute("data-sourcepos") }
        end

        def view
          @view ||= ViewContext.build
        end
    end
  end
end
