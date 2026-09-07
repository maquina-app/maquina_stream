# frozen_string_literal: true

require "test_helper"

module MaquinaStream
  # The regression suite the sanitizer is judged by.
  #
  # Every file in test/fixtures/xss becomes its own test case. Adding an attack
  # is adding a file — no edit here, and no way to add one that is quietly not
  # run.
  class SanitizerTest < ActiveSupport::TestCase
    CORPUS_DIR = File.expand_path("../fixtures/xss", __dir__)

    # Nothing on this list may appear in output, whatever the input said.
    FORBIDDEN_ELEMENTS = %w[
      script style iframe object embed svg math form button input template
      noscript base meta link frame frameset applet textarea select
    ].freeze

    FORBIDDEN_ATTRIBUTES = %w[srcdoc formaction style xlink:href xml:base action
      http-equiv background ping].freeze

    DANGEROUS_SCHEME = /\A[\s\u0000-\u0020]*(?:javascript|vbscript|livescript|mocha|jscript|data|file|blob|about|view-source)\s*:/i

    # An entry: `--- input` then `--- note`. The note names the attack and says
    # what must survive; it is documentation for whoever reads a failure.
    Entry = Struct.new(:name, :input, :note) do
      def self.load(path)
        body = File.read(path)
        input = body[/^--- input\n(.*?)^--- note\n/m, 1]
        note = body[/^--- note\n(.*)\z/m, 1]

        new(File.basename(path, ".txt"), input&.chomp, note&.strip)
      end
    end

    def self.corpus
      Dir[File.join(CORPUS_DIR, "*.txt")].sort
    end

    test "the corpus is not empty" do
      assert_operator self.class.corpus.size, :>=, 25,
        "the XSS corpus is the regression suite; it does not shrink"
    end

    corpus.each do |path|
      entry = Entry.load(path)

      define_method("test_xss_corpus_#{entry.name}") do
        assert entry.input.present?, "#{entry.name}: missing an `--- input` section"
        assert entry.note.present?, "#{entry.name}: missing an `--- note` section"

        output = Sanitizer.call(entry.input)
        assert_neutralized entry, output

        # The sanitizer is the last pass, so it must also be a fixed point:
        # sanitizing its own output changes nothing an attacker can use.
        assert_neutralized entry, Sanitizer.call(output)
      end
    end

    # --- Positive behaviour: what must survive ---------------------------

    test "rendered markdown survives intact" do
      html = <<~HTML
        <h2 id="ms-1-b0">Title</h2>
        <p>Text with <strong>bold</strong>, <em>italic</em> and <code>code</code>.</p>
        <ul><li>one</li><li>two</li></ul>
        <table><thead><tr><th scope="col">a</th></tr></thead><tbody><tr><td colspan="2">b</td></tr></tbody></table>
        <blockquote><p>a quote</p></blockquote>
        <pre><code class="language-ruby">puts 1</code></pre>
      HTML

      output = Sanitizer.call(html)

      %w[h2 strong em code ul li table thead th td blockquote pre].each do |tag|
        assert_includes output, "<#{tag}", "#{tag} must survive"
      end
      assert_includes output, 'id="ms-1-b0"'
      assert_includes output, 'class="language-ruby"'
      assert_includes output, "puts 1"
    end

    test "our own block and controller hooks survive" do
      html = <<~HTML
        <div id="ms-1-b1" data-ms-block-index="1" data-ms-block-digest="a91c" data-ms-block-state="open"
             data-controller="ms-code ms-reveal" data-ms-code-lang-value="ruby"
             data-action="click->ms-code#copy" data-component="code-block" data-turbo-permanent>x</div>
      HTML

      output = Sanitizer.call(html)

      assert_includes output, 'data-ms-block-index="1"'
      assert_includes output, 'data-ms-block-state="open"'
      assert_includes output, 'data-controller="ms-code ms-reveal"'
      assert_includes output, 'data-ms-code-lang-value="ruby"'
      assert_includes output, 'data-action="click->ms-code#copy"'
      assert_includes output, 'data-component="code-block"'
      assert_includes output, "data-turbo-permanent"
    end

    test "a third party controller and its values are dropped" do
      output = Sanitizer.call(%(<div data-controller="ms-code evil" data-evil-url-value="x">t</div>))

      assert_includes output, 'data-controller="ms-code"'
      refute_includes output, "evil-url-value"
    end

    test "allowed protocols pass and everything else does not" do
      assert_includes Sanitizer.call(%(<a href="https://example.com/a">x</a>)), 'href="https://example.com/a"'
      assert_includes Sanitizer.call(%(<a href="mailto:a@example.com">x</a>)), 'href="mailto:a@example.com"'
      refute_includes Sanitizer.call(%(<a href="ftp://example.com/a">x</a>)), "href"
    end

    test "a same document fragment link survives" do
      assert_includes Sanitizer.call(%(<a href="#section">x</a>)), 'href="#section"'
    end

    test "external links get noopener and noreferrer" do
      output = Sanitizer.call(%(<a href="https://example.com">x</a>))

      assert_includes output, "noopener"
      assert_includes output, "noreferrer"
    end

    test "relative urls are rewritten against default_origin when it is set" do
      MaquinaStream.configure { |c| c.default_origin = "https://cdn.example.com/base/" }

      assert_includes Sanitizer.call(%(<a href="doc.html">x</a>)), 'href="https://cdn.example.com/base/doc.html"'
      assert_includes Sanitizer.call(%(<img src="/i/a.png" alt="a">)), 'src="https://cdn.example.com/i/a.png"'
    end

    test "relative urls are left alone when default_origin is unset" do
      assert_nil MaquinaStream.config.default_origin
      assert_includes Sanitizer.call(%(<a href="/doc.html">x</a>)), 'href="/doc.html"'
    end

    test "link and image prefixes are honoured" do
      MaquinaStream.configure do |c|
        c.allowed_link_prefixes = ["https://example.com/"]
        c.allowed_image_prefixes = ["https://cdn.example.com/"]
      end

      assert_includes Sanitizer.call(%(<a href="https://example.com/ok">x</a>)), "href"
      refute_includes Sanitizer.call(%(<a href="https://other.example/no">x</a>)), "href"
      assert_includes Sanitizer.call(%(<img src="https://cdn.example.com/a.png" alt="a">)), "<img"
      refute_includes Sanitizer.call(%(<img src="https://example.com/a.png" alt="a">)), "<img"
    end

    test "a star prefix allows any url on an allowed protocol" do
      assert_equal ["*"], MaquinaStream.config.allowed_link_prefixes
      assert_includes Sanitizer.call(%(<a href="https://anything.example/x">x</a>)), "href"
    end

    test "data images pass only as base64 raster and only when enabled" do
      png = "data:image/png;base64,iVBORw0KGgo="

      assert_includes Sanitizer.call(%(<img src="#{png}" alt="a">)), png

      MaquinaStream.configure { |c| c.allow_data_images = false }
      refute_includes Sanitizer.call(%(<img src="#{png}" alt="a">)), "<img"
    end

    test "a data image is never accepted in a link" do
      refute_includes Sanitizer.call(%(<a href="data:image/png;base64,iVBORw0KGgo=">x</a>)), "href"
    end

    test "the tasklist checkbox survives and is always disabled" do
      output = Sanitizer.call(%(<li><input type="checkbox" checked> task</li>))

      assert_includes output, "<input"
      assert_includes output, "disabled"
      assert_includes output, "task"
    end

    test "text inside a fenced code block survives verbatim" do
      source = %(x = "<script>alert(1)</script>" # onload=)
      html = "<pre><code>#{ERB::Util.html_escape(source)}</code></pre>"

      output = Sanitizer.call(html)

      assert_equal source, Nokogiri::HTML5.fragment(output).at("code").text
      refute_match(/<script/i, output)
    end

    test "an explicit config is used over the global one" do
      config = MaquinaStream::Configuration.new
      config.allowed_protocols = %w[https]

      refute_includes Sanitizer.call(%(<a href="http://example.com">x</a>), config: config), "href"
      assert_includes Sanitizer.call(%(<a href="https://example.com">x</a>), config: config), "href"
    end

    test "blank input is blank output" do
      assert_equal "", Sanitizer.call(nil)
      assert_equal "", Sanitizer.call("")
    end

    private
      def assert_neutralized(entry, output)
        fragment = Nokogiri::HTML5.fragment(output)
        context = "#{entry.name}: #{entry.note}\n  output: #{output.inspect}"

        refute_match(/<script/i, output, context)

        FORBIDDEN_ELEMENTS.each do |tag|
          next if tag == "input" && fragment.css("input").all? { |i| i["type"] == "checkbox" }

          assert_empty fragment.css(tag), "#{tag} element survived — #{context}"
        end

        fragment.traverse do |node|
          next unless node.element?

          node.attribute_nodes.each do |attr|
            name = attr.name.downcase
            qualified = attr.namespace ? "#{attr.namespace.prefix}:#{name}" : name

            refute name.start_with?("on"), "#{qualified} handler survived — #{context}"
            refute_includes FORBIDDEN_ATTRIBUTES, qualified, "#{qualified} survived — #{context}"
            next if attr.value.to_s.match?(MaquinaStream::Sanitizer::DATA_IMAGE)
            refute_match DANGEROUS_SCHEME, attr.value.to_s,
              "#{qualified} carries a dangerous scheme — #{context}"
          end
        end
      end
  end
end
