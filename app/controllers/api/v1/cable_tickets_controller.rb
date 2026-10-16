module Api
  module V1
    class CableTicketsController < BaseController
      def create
        ticket = CableTicket.issue!(current_user)

        render_resource(ticket, status: :created)
      end
    end
  end
end
