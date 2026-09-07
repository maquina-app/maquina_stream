# frozen_string_literal: true

require "digest"

module MaquinaStream
  # One top-level block of a message: the slice of raw markdown it came from,
  # the HTML it rendered to, and whether it is safe to freeze.
  #
  # The id is derived from the index and never from the content. Idiomorph keys
  # on id, so a content-derived id turns every edit into a delete-and-recreate,
  # which loses scroll position, animation state and anything the client owns.
  #
  # Blocks come from Document. Building one by hand is possible but rarely
  # useful: the id and digest a repair needs are stamped on during that split.
  # Instances are immutable — #seal returns a new Block rather than mutating.
  class Block
    # This block's position in the document, zero-based. The id is derived from
    # it.
    attr_reader :index

    # The slice of raw markdown this block was rendered from.
    attr_reader :markdown

    # The rendered HTML for this block alone, including its own element and the
    # `id`, `data-ms-block` and `data-ms-block-digest` attributes.
    attr_reader :html

    # The Range of 1-based source lines this block covers. Coverage has gaps —
    # an HTML block reports no source position at all — so a block with no
    # range of its own inherits the lines between its neighbours.
    attr_reader :line_range

    # The stream id this block belongs to, or nil for an anonymous render.
    attr_reader :sid

    # Builds a block. Document does this; a host normally reads blocks rather
    # than constructing them.
    def initialize(index:, markdown:, html:, line_range:, sid: nil, sealed: false, digest: nil)
      @index = index
      @markdown = markdown
      @html = html
      @line_range = line_range
      @sid = sid
      @sealed = sealed
      @digest = digest
    end

    # The DOM id, `ms-<sid>-b<index>`. Index-derived, never content-derived:
    # idiomorph keys on it.
    def id
      sid ? "ms-#{sid}-b#{index}" : "ms-b#{index}"
    end

    # Whether this block is frozen — far enough behind the tail that nothing
    # can reinterpret it, and therefore never re-broadcast.
    def sealed? = @sealed

    # Whether this block can still change, and can therefore still be patched.
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

    # A copy of this block, sealed. Returns a new Block; the receiver is
    # unchanged.
    def seal
      self.class.new(
        index: index, markdown: markdown, html: html,
        line_range: line_range, sid: sid, sealed: true, digest: digest
      )
    end

    # `[id, digest]` — one row of a Manifest, and the unit the client diffs
    # its own DOM against.
    def to_manifest_entry = [id, digest]

    # Two blocks are equal when they hold the same index and the same HTML.
    # Sealing is deliberately not part of it: a block that sealed between two
    # frames is the same block, and the seal is a decision about it rather than
    # a property of it.
    def ==(other)
      other.is_a?(Block) && other.index == index && other.html == html
    end
    alias_method :eql?, :==

    # Hashed on the same two fields #== compares.
    def hash = [index, html].hash
  end
end
