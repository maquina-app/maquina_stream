# frozen_string_literal: true

module MaquinaStream
  # Which way a piece of text reads.
  #
  # A message is one document but not necessarily one direction: an assistant
  # answering in Arabic quotes an English identifier, a Hebrew paragraph sits
  # next to a Ruby fence. Direction is therefore decided per block, the way the
  # bidi algorithm decides it — by the FIRST STRONG character — and not by the
  # document, the locale or the host.
  #
  # `dir="auto"` on every block would let the browser do exactly this, at the
  # cost of eleven bytes on every block of every frame for the majority of
  # documents that are left-to-right and need nothing. So the strong character
  # is found here and the attribute is emitted only when it changes something.
  module TextDirection
    # The scripts written right to left, as Ruby knows them.
    RTL = /[\p{Hebrew}\p{Arabic}\p{Syriac}\p{Thaana}\p{Nko}\p{Samaritan}\p{Mandaic}\p{Adlam}]/

    # Only a letter is strong. Digits, punctuation and whitespace take their
    # direction from what surrounds them, which is why "١٢٣ Ruby" reads
    # left-to-right and "مرحبا 123" does not.
    STRONG = /[\p{L}\p{Nl}]/

    # Explicit bidi controls. They are what a Trojan Source attack is made of:
    # an override inside a comment reorders the rendering of code that the
    # parser reads in a different order entirely.
    CONTROLS = /[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/

    # :rtl, :ltr, or nil when nothing in the text is strong either way.
    def self.of(text)
      strong = text.to_s[STRONG]
      return nil unless strong

      strong.match?(RTL) ? :rtl : :ltr
    end

    def self.controls?(text)
      text.to_s.match?(CONTROLS)
    end
  end
end
