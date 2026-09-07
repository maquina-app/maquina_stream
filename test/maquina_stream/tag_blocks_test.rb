# frozen_string_literal: true

require "test_helper"

module MaquinaStream
  # Renderer::TagBlocks is a transform over model-written text that changes how
  # that text is parsed, so it is tested as a privilege boundary rather than as
  # a formatter: what it refuses to touch matters more than what it rewrites.
  class TagBlocksTest < ActiveSupport::TestCase
    NAMES = %w[thinking citation].freeze

    setup { MaquinaStream.reset_registries! }

    teardown { MaquinaStream.reset_registries! }

    # --- What it does ----------------------------------------------------

    test "a block-level tag gets a blank line after its opener and before its closer" do
      assert_equal "<thinking>\n\nFirst.\n\nSecond.\n\n</thinking>\n\nAfter.\n",
        normalize("<thinking>\nFirst.\n\nSecond.\n</thinking>\n\nAfter.\n")
    end

    test "a closer with prose in front of it is moved onto a block of its own" do
      assert_equal "<thinking>\n\nFirst.\n\n</thinking>\n\n After the tag.\n",
        normalize("<thinking>\nFirst.\n</thinking> After the tag.\n")
    end

    test "it is idempotent" do
      once = normalize("<thinking>\nFirst.\n\nSecond.\n</thinking>\n\nAfter.\n")

      assert_equal once, normalize(once)
    end

    test "nested tags of the same name are matched innermost first" do
      assert_equal "<thinking>\n\nouter\n\n<thinking>\n\ninner\n\n</thinking>\n\nend\n\n</thinking>\n",
        normalize("<thinking>\nouter\n\n<thinking>\ninner\n</thinking>\n\nend\n</thinking>\n")
    end

    # --- What it refuses to touch ----------------------------------------

    test "an empty registry returns the buffer byte for byte" do
      source = "<thinking>\nFirst.\n\nSecond.\n</thinking>\n"

      assert_same source, MaquinaStream::Renderer::TagBlocks.call(source, names: [])
    end

    test "an unregistered tag is never normalised" do
      %w[script iframe img div thinkingXYZ].each do |name|
        source = "<#{name}>\nFirst.\n\nSecond.\n</#{name}>\n\nAfter.\n"

        assert_equal source, normalize(source), "<#{name}> is not registered and must not be touched"
      end
    end

    test "a registered name inside a fenced code block is code" do
      %W[```\n ~~~\n ```ruby\n].each do |fence|
        source = "#{fence}<thinking>\nx\n</thinking>\n#{fence[0, 3]}\n\nAfter.\n"

        assert_equal source, normalize(source)
      end
    end

    test "a registered name inside an unterminated fence is code" do
      source = "```\n<thinking>\nx\n</thinking>\n"

      assert_equal source, normalize(source)
    end

    test "a registered name inside an inline code span is code" do
      source = "Write `<thinking>` and close it with `</thinking>` when done.\n"

      assert_equal source, normalize(source)
    end

    test "a registered name inside an indented code block is code" do
      source = "Example:\n\n    <thinking>\n    x\n\n    </thinking>\n"

      assert_equal source, normalize(source)
    end

    test "a registered name inside a raw HTML region is not markup" do
      [
        "<!--\n<thinking>\nhidden\n</thinking>\n-->\n\nAfter.\n",
        "<script>\n<thinking>\nvar x\n</thinking>\n</script>\n\nAfter.\n",
        "<pre>\n<thinking>\nx\n</thinking>\n</pre>\n\nAfter.\n",
        "<style>\n<thinking>\nx\n</thinking>\n</style>\n\nAfter.\n",
        "<textarea>\n<thinking>\nx\n</thinking>\n</textarea>\n\nAfter.\n",
        "<![CDATA[\n<thinking>\nx\n</thinking>\n]]>\n\nAfter.\n",
        "<?php\n<thinking>\nx\n</thinking>\n?>\n\nAfter.\n"
      ].each do |source|
        assert_equal source, normalize(source),
          "a blank line inserted inside a raw region would end it early and publish what it hid"
      end
    end

    test "an inline tag in the middle of a sentence is left as the model wrote it" do
      source = "The model wrote <citation>source 3</citation> mid-sentence.\n"

      assert_equal source, normalize(source)
    end

    test "an opener with no closer inserts nothing" do
      source = "<thinking>\nStill reasoning.\n\nStill going.\n"

      assert_equal source, normalize(source)
    end

    test "a closer with no opener inserts nothing" do
      source = "Text.\n\n</thinking>\n\nMore text.\n"

      assert_equal source, normalize(source)
    end

    test "a self closing tag opens nothing" do
      source = "<citation id=\"1\"/>\n\nAfter.\n"

      assert_equal source, normalize(source)
    end

    test "a tag broken across a newline is not a complete tag" do
      source = "<thinking\n  data-x=\"1\">\nFirst.\n\nSecond.\n</thinking>\n"

      assert_equal source, normalize(source)
    end

    test "a tag whose closing bracket has not arrived is not a tag" do
      source = "<thinking data-x=\"1\"\n"

      assert_equal source, normalize(source)
    end

    test "an attribute value may contain a greater than sign" do
      assert_equal %(<thinking title="a>b">\n\nx\n\n</thinking>\n),
        normalize(%(<thinking title="a>b">\nx\n</thinking>\n))
    end

    test "an unterminated quoted attribute is not a tag" do
      source = %(<thinking title="a\nx\n\ny\n</thinking>\n\nAfter.\n)

      assert_equal source, normalize(source)
    end

    test "case is matched the way HTML matches it" do
      assert_equal "<THINKING>\n\na\n\n</Thinking>\n",
        normalize("<THINKING>\na\n</Thinking>\n")
    end

    # --- Properties over every prefix of a hostile document ---------------

    # Everything a model might write around a registered tag, in one buffer: a
    # forged closer inside a fence, a comment holding the tag name and a script,
    # an inline tag, an image with a handler, and a table under it all.
    ADVERSARIAL = <<~MARKDOWN
      Intro **bold** text.

      <thinking>
      Reasoning with `code` and a [link](https://example.com).

      ```html
      </thinking>
      <img src=x onerror=alert(1)>
      ```

      More reasoning <citation id="9">fuente</citation> here.
      </thinking>

      <!-- <thinking> oculto </thinking> <script>alert(2)</script> -->

      Answer paragraph with <img src=y onerror=alert(3)> inline.

      | a | b |
      |---|---|
      | 1 | 2 |
    MARKDOWN

    # The transform's whole licence: it may insert newlines and it may do
    # nothing else. Asserted over every truncation point, because a stream is
    # rendered from every prefix of itself and a frame boundary can fall
    # anywhere — including in the middle of a tag.
    test "over every prefix it inserts newlines and nothing else, and stays idempotent" do
      (0..ADVERSARIAL.length).each do |cut|
        source = MaquinaRemend.call(ADVERSARIAL[0, cut])
        once = normalize(source)

        assert_equal source.delete("\n"), once.delete("\n"),
          "the transform changed a character other than a newline at truncation point #{cut}"
        assert_equal once, normalize(once),
          "the transform is not idempotent at truncation point #{cut}"
      end
    end

    # --- Through the whole pipeline --------------------------------------

    # The XSS corpus is written against the sanitizer. Running every entry
    # through the whole renderer as well, with app-meaning tags registered, asks
    # the other question: whether this transform can turn one of those payloads
    # into markup. It cannot introduce an element or an attribute the allowlist
    # does not name, because the sanitizer still runs last and unconditionally.
    CORPUS = Dir[File.expand_path("../fixtures/xss/*.txt", __dir__)].sort

    FORBIDDEN_ELEMENTS = %w[
      script style iframe object embed svg math form template noscript base
      meta link frame frameset applet textarea select
    ].freeze

    DANGEROUS_SCHEME = /\A[\s\u0000-\u0020]*(?:javascript|vbscript|livescript|mocha|jscript|data|file|blob|about|view-source)\s*:/i

    CORPUS.each do |path|
      name = File.basename(path, ".txt")

      test "corpus #{name} is inert when rendered with tags registered" do
        %i[thinking answer citation tool_call].each do |tag|
          MaquinaStream.register_tag tag, attributes: [], partial: "tags/reasoning"
        end

        assert_inert name, File.read(path)[/^--- input\n(.*?)^--- note\n/m, 1].to_s.chomp
      end
    end

    # A host that registers a name the sanitizer drops has made a mistake, not a
    # hole: the tag is normalised into its own block, the partial renders, and
    # the sanitizer removes the element and its subtree anyway. The transform
    # never widens what may survive.
    test "registering a dangerous name does not make it survive" do
      %i[script iframe object].each do |tag|
        MaquinaStream.register_tag tag, attributes: [], partial: "tags/reasoning"
      end

      assert_inert "registered script", "<script>\nalert(1)\n\nalert(2)\n</script>\n\nAfter.\n"
      assert_inert "registered iframe", "<iframe src=\"javascript:alert(1)\">\nx\n\ny\n</iframe>\n"
    end

    private
      # The same properties the sanitizer corpus asserts, read off the DOM
      # rather than off the string: an escaped payload in a text node or an
      # attribute value is inert, and only markup counts.
      def assert_inert(label, markdown)
        html = MaquinaStream::Renderer.call(markdown, mode: :static).to_s
        fragment = Nokogiri::HTML5.fragment(html)
        context = "#{label}\n  markdown: #{markdown.inspect}\n  output: #{html.inspect}"

        refute_match(/<script/i, html, context)

        FORBIDDEN_ELEMENTS.each do |tag|
          assert_empty fragment.css(tag), "#{tag} element survived — #{context}"
        end

        fragment.traverse do |node|
          next unless node.element?

          node.attribute_nodes.each do |attr|
            attr_name = attr.name.downcase

            refute attr_name.start_with?("on"), "#{attr_name} handler survived — #{context}"
            next unless %w[href src].include?(attr_name)

            refute_match DANGEROUS_SCHEME, attr.value.to_s,
              "#{attr_name} carries a dangerous scheme — #{context}"
          end
        end
      end

      def normalize(markdown, names: NAMES)
        MaquinaStream::Renderer::TagBlocks.call(markdown, names: names)
      end
  end
end
