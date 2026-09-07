# frozen_string_literal: true

module MaquinaStream
  module Components
    # The engine's half of a vendored component.
    #
    # A vendored partial is a +maquina_components+ component that happens to
    # live here for now: it knows about variants, parts and +css_classes+, and
    # about nothing else. Everything that belongs to THIS engine — the
    # +data-ms-*+ DOM contract from docs/api-surface.md, the +ms-*+ Stimulus
    # identifiers, and the +maquina_stream.*+ labels — is supplied from the call
    # site, and this is the call site.
    #
    #   Contract.apply(:code_block, {lang: "ruby", source: raw}, config: config)
    #   # => {lang: "ruby", source: raw,
    #   #     data: {ms_code: "", ms_code_lang: "ruby"},
    #   #     source_attributes: {"data-ms-code-source" => ""},
    #   #     copy_label: "Copiar", …}
    #
    # Two callers, and only two: +ComponentsHelper#component+ and the fence
    # renderer in Renderer::PostPass, which renders the same partial from
    # outside a request. Extraction deletes nothing here — this file is what
    # the engine keeps when the partials leave.
    #
    # Caller locals win over ours, so a host can name a label itself. The
    # exception is +data+, which is merged rather than replaced: the DOM
    # contract is not the host's to drop, and +controller+ concatenates so a
    # host's own controller rides along with ours.
    module Contract
      class << self
        def apply(name, locals, config: MaquinaStream.config)
          engine = engine_locals(name.to_sym, locals, config)
          return locals if engine.empty?

          data = merge_data(engine.delete(:data) || {}, locals[:data] || locals["data"])
          merged = engine.merge(locals)
          merged.delete("data")
          merged[:data] = data unless data.empty?
          merged
        end

        # Same rule as ComponentsHelper#component_data, applied one level
        # earlier: ours wins its own keys, +controller+ and +action+
        # concatenate with ours first. The helper travels to
        # +maquina_components+ with the partials; this stays, so the rule is
        # written out here rather than borrowed.
        def merge_data(own, provided)
          own = own.compact
          provided = (provided || {}).transform_keys { |key| key.to_s.tr("-", "_").to_sym }

          provided.merge(own) do |key, theirs, ours|
            %i[controller action].include?(key) ? [ours, theirs].compact.join(" ").strip : ours
          end.compact
        end

        private

        def engine_locals(name, locals, config)
          case name
          when :code_block then code_block(locals)
          when :snippet then snippet
          when :attachment then attachment(locals, config)
          when :suggestion then suggestion(config)
          else {}
          end
        end

        # `ms-code` reads the `<pre hidden data-ms-code-source>` carrier and the
        # `data-ms-code-lang` attribute; `data-ms-control` is what the stream
        # guard disables while a message is still being written.
        #
        # Controls are NOT defaulted from configuration here. The fence renderer
        # decides them — an open fence gets none — and a host asking for a bare
        # code block gets a bare code block.
        def code_block(locals)
          controls = locals[:controls] || {}

          {
            data: {
              ms_code: "",
              ms_code_lang: presence(locals[:lang]),
              controller: ("ms-code" if controls.present?)
            },
            source_attributes: {"data-ms-code-source" => ""},
            copy_attributes: {"data-ms-control" => "", "data-action" => "ms-code#copy"},
            download_attributes: {"data-ms-control" => "", "data-action" => "ms-code#download"},
            copy_label: translate("code.copy", "Copy"),
            copy_aria_label: translate("code.copy_code", "Copy the code"),
            download_label: translate("code.download", "Download"),
            download_aria_label: translate("code.download_code", "Download the code")
          }
        end

        def snippet
          {
            data: {controller: "ms-code"},
            source_attributes: {"data-ms-code-source" => ""},
            copy_attributes: {"data-action" => "ms-code#copy"},
            copy_label: translate("snippet.copy", "Copy"),
            copy_aria_label: translate("snippet.copy_command", "Copy the command")
          }
        end

        # A `translate` default is only ever reached when a host has neither
        # locale loaded, so it is the language of last resort and is English —
        # es.yml and en.yml are where the real strings live, and Spanish being
        # the engine's DEFAULT LOCALE is a matter of which file I18n reads, not
        # of which language is compiled into the source.

        # The host renders attachments, so the engine's control switches are
        # read here rather than in the partial: a generic component does not
        # know what MaquinaStream.config is.
        def attachment(locals, config)
          label = presence(locals[:filename].to_s) || translate("attachment.unnamed", "Attachment")
          thumbnail = locals[:content_type].to_s.start_with?("image/") && presence(locals[:preview_url])

          {
            controls: config.controls[:attachment],
            unnamed_label: translate("attachment.unnamed", "Attachment"),
            download_label: translate("attachment.download", "Download"),
            download_aria_label: translate("attachment.download_file", "Download %{name}", name: label),
            remove_label: translate("attachment.remove", "Remove"),
            remove_aria_label: translate("attachment.remove_file", "Remove %{name}", name: label),
            remove_confirm: translate("attachment.remove_confirm", "Remove this attachment?"),
            size_units: size_units,
            size_format: translate("attachment.size", "%{value} %{unit}"),
            decimal_separator: translate("number.decimal_separator", "."),
            data: {
              controller: ("ms-attachment" if thumbnail),
              ms_attachment_content_type: presence(locals[:content_type])
            },
            thumbnail_attributes: thumbnail ? thumbnail_attributes : {},
            download_attributes: {"data-ms-attachment-target" => "download"}
          }
        end

        def thumbnail_attributes
          {
            "data-ms-attachment-target" => "thumbnail",
            "data-action" => "error->ms-attachment#thumbnailFailed"
          }
        end

        def suggestion(config)
          {
            controls: config.controls[:suggestion],
            label: translate("suggestion.list_label", "Suggestions")
          }
        end

        # The unit names are labels like any other: ActiveSupport ships English
        # only, so the default locale would otherwise have nothing to name them
        # with.
        def size_units
          %w[bytes kb mb gb tb].map { |unit| translate("attachment.units.#{unit}", unit) }
        end

        def translate(key, fallback, **interpolations)
          I18n.t("maquina_stream.#{key}", default: fallback, **interpolations)
        end

        def presence(value)
          value.to_s.empty? ? nil : value
        end
      end
    end
  end
end
