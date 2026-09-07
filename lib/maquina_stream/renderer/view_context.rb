# frozen_string_literal: true

module MaquinaStream
  class Renderer
    # Renders engine partials without a request.
    #
    # The renderer is a pure function, but components are ERB — so it builds its
    # own view context from the engine's view paths rather than borrowing a
    # controller's. "No request context" is the constraint; ActionView is not
    # request context.
    class ViewContext
      class MissingActionView < Error; end

      def self.build
        @build ||= new
      end

      # Templates are looked up once per process, so a component change in
      # development needs a reload — the same trade every engine partial makes.
      def self.reset!
        @build = nil
      end

      def render(partial, locals = {})
        view.render(partial: partial, locals: locals)
      end

      private
        def view
          @view ||= begin
            require_action_view!

            lookup = ActionView::LookupContext.new(view_paths)
            view = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
            # Components render through the seam, and the seam is a helper.
            view.extend(MaquinaStream::ComponentsHelper)
            view
          end
        end

        def view_paths
          if defined?(ActionController::Base)
            ActionController::Base.view_paths
          else
            [File.expand_path("../../../app/views", __dir__)]
          end
        end

        def require_action_view!
          return if defined?(ActionView::Base)

          raise MissingActionView, <<~MESSAGE
            MaquinaStream::Renderer needs ActionView to render component partials.
            It does not need a request, a controller or a running server — but it
            is an engine, and its components are ERB.
          MESSAGE
        end
    end
  end
end
