# frozen_string_literal: true

# History pagination, loading upward — the documented pattern, in the dummy app
# so it is a working example rather than prose.
#
# The engine does not paginate: which messages belong to a conversation, and in
# what order, is the host's business. What the engine provides is what makes
# paginating cheap — a sealed message is immutable, so `MaquinaStream.render`
# serves it from cache by digest instead of re-rendering a page of history on
# every load.
class HistoryController < ActionController::Base
  layout "application"

  PER_PAGE = 10

  def index
    before = params[:before].presence&.to_i

    scope = Message.order(id: :desc)
    scope = scope.where(id: ...before) if before

    @messages = scope.limit(PER_PAGE).to_a.reverse
    @older = @messages.any? && Message.where(id: ...@messages.first.id).exists?
    @frame = before ? "history-before-#{before}" : nil
  end
end
