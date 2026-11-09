module Trivia
  # Plain JSON endpoints for the trivia game show. Inherits from
  # ActionController::API rather than ApplicationController so that Devise,
  # CSRF tokens, the modern-browser gate and view rendering all stay out of the
  # way — players hit this from whatever phone they have in their pocket.
  class BaseController < ActionController::API
    before_action :set_cors_headers

    # The frontend is served from another origin (milktruck-web), so every
    # response needs CORS headers and OPTIONS needs an answer. Wide open on
    # purpose: there is nothing private in here.
    def preflight
      head :no_content
    end

    private

      def set_cors_headers
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Methods"] = "GET, POST, PATCH, DELETE, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, X-Admin-Token"
        headers["Access-Control-Max-Age"] = "86400"
      end

      def game
        @game ||= TriviaGame.current
      end

      def admin?
        token = request.headers["X-Admin-Token"].presence || params[:admin_token].presence
        token == TriviaGame::ADMIN_TOKEN
      end

      def require_admin!
        render json: { error: "Host only" }, status: :forbidden unless admin?
      end
  end
end
