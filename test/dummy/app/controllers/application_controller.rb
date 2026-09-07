# frozen_string_literal: true

# Nothing inherits from this. It exists because a Turbo broadcast renders its
# partial through `ApplicationController.renderer` — a broadcast happens outside
# any request, so there is no controller to borrow a view context from — and
# turbo-rails names that constant rather than asking for one.
class ApplicationController < ActionController::Base
end
