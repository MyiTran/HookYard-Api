module ApiError
  class NotAuthorizedError < StandardError
    def initialize(message = nil)
      super(
        message: message || 'Permission Denied',
        status: 403
      )
    end
  end
end
