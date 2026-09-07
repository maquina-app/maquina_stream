# frozen_string_literal: true

# The repair path, as the browser performs it.
#
# Fetch the manifest, compare it against what the client holds, ask for the
# blocks whose digests differ, apply them, and drop anything the server no
# longer claims. `ms-repair` does exactly this over HTTP; this does it in
# process, so the invariant can be asserted without a browser.
#
# It exists because the delta stream alone does **not** converge, by design:
# Phase 3 patches the open tail only, so a block that changes after it stops
# being the tail stays wrong on the client until repair. Any test that claims
# convergence has to run this step, or it is testing a weaker claim than the
# architecture makes.
class RepairSimulator
  attr_reader :record

  def initialize(record)
    @record = record
  end

  def repair(client_dom)
    manifest = MaquinaStream::Manifest.for(record)
    wanted = manifest.diff(digests_of(client_dom))

    repaired = client_dom.merge(serve(wanted))
    repaired.slice(*document.sealed_blocks.map(&:id))
  end

  def truth
    document.sealed_blocks.to_h { |block| [block.id, block.html] }
  end

  private
    def document
      MaquinaStream::Document.new(
        record.maquina_stream_buffer, sid: record.maquina_stream_id, mode: :static
      )
    end

    # The client digests what it holds the same way the server does: the block's
    # content, read back off the element the server stamped.
    def digests_of(client_dom)
      client_dom.filter_map do |id, html|
        node = Nokogiri::HTML5.fragment(html).children.find(&:element?)
        node && [id, node["data-ms-block-digest"]]
      end
    end

    def serve(ids)
      document.blocks.select { |block| ids.include?(block.id) }
        .to_h { |block| [block.id, block.html] }
    end
end
