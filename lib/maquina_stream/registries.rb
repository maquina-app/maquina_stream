# frozen_string_literal: true

module MaquinaStream
  # Registrations are stored here in Phase 1. Phase 2 (render pipeline) reads
  # them; nothing consumes them yet.
  Element = Struct.new(:name, :options, keyword_init: false)
  Tag = Struct.new(:name, :options, keyword_init: false)
  Fence = Struct.new(:info, :options, keyword_init: false)

  module Registries
    def elements = @elements ||= {}
    def tags = @tags ||= {}
    def fences = @fences ||= {}

    # MaquinaStream.register_element :h2, partial: "my/headings/h2"
    def register_element(name, **options)
      elements[name.to_sym] = Element.new(name.to_sym, options)
    end

    # MaquinaStream.register_tag :source, attributes: %w[id], partial: "…",
    #                            literal_content: false
    def register_tag(name, **options)
      tags[name.to_sym] = Tag.new(name.to_sym, options)
    end

    # MaquinaStream.register_fence "ruby", strategy: :server
    def register_fence(info, **options)
      fences[info.to_s] = Fence.new(info.to_s, options)
    end

    def reset_registries!
      @elements = {}
      @tags = {}
      @fences = {}
    end
  end
end
