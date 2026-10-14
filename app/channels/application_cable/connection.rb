module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = CableTicket.consume(request.params[:ticket])
      reject_unauthorized_connection if current_user.nil?
    end
  end
end
