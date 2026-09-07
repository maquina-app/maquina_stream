# frozen_string_literal: true

require "digest"

module MaquinaStream
  # One top-level block of a message: the slice of raw markdown it came from,
  # the HTML it rendered to, and whether it is safe to freeze.
  #
  # The id is derived from the index and never from the content. Idiomorph keys
  # on id, so a content-derived id turns every edit into a delete-and-recreate,
  # which loses scroll position, animation state and anything the client owns.
  class Block
    attr_reader :index, :markdown, :html, :line_range, :sid

    def initialize(index:, markdown:, html:, line_range:, sid: nil, sealed: false, digest: nil)
      @index = index
      @markdown = markdown
      @html = html
      @line_range = line_range
      @sid = sid
      @sealed = sealed
      @digest = digest
    end

    def id
      sid ? "ms-#{sid}-b#{index}" : "ms-b#{index}"
    end

    def sealed? = @sealed

    def open? = !sealed?

    # Digest of the block's rendered CONTENT, not of the source and not of the
    # whole element.
    #
    # The manifest compares what the browser actually has, so two different
    # sources that render alike need no repair between them. Element-level
    # attributes are excluded on purpose: a block gains `data-ms-block-state`
    # when it seals and loses `data-ms-caret` when the tail moves past it, and
    # neither changes what the block says. Digesting them would make every block
    # in every message fetch itself once, for nothing.
    def digest
      @digest ||= Digest::SHA256.hexdigest(html.to_s)[0, 16]
    end

    def seal
      self.class.new(
        index: index, markdown: markdown, html: html,
        line_range: line_range, sid: sid, sealed: true, digest: digest
      )
    end

    def to_manifest_entry = [id, digest]

    def ==(other)
      other.is_a?(Block) && other.index == index && other.html == html
    end
    alias_method :eql?, :==

    def hash = [index, html].hash
  end
end
