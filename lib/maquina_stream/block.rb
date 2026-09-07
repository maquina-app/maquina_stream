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

    def initialize(index:, markdown:, html:, line_range:, sid: nil, sealed: false)
      @index = index
      @markdown = markdown
      @html = html
      @line_range = line_range
      @sid = sid
      @sealed = sealed
    end

    def id
      sid ? "ms-#{sid}-b#{index}" : "ms-b#{index}"
    end

    def sealed? = @sealed

    def open? = !sealed?

    # Digest of the rendered HTML, not of the source. The manifest compares what
    # the browser actually has, and two different sources that render to the same
    # HTML need no repair between them.
    def digest
      @digest ||= Digest::SHA256.hexdigest(html.to_s)[0, 16]
    end

    def seal
      self.class.new(
        index: index, markdown: markdown, html: html,
        line_range: line_range, sid: sid, sealed: true
      )
    end

    def to_manifest_entry = [id, digest]

    def ==(other)
      other.is_a?(Block) && other.index == index && other.html == html
    end
    alias eql? ==

    def hash = [index, html].hash
  end
end
