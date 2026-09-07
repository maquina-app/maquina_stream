# frozen_string_literal: true

# Harness only. The engine appends its own pins to this via its importmap
# initializer, exactly as a real host would receive them.
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
