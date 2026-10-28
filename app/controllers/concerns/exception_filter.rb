module ExceptionFilter
  extend ActiveSupport::Concern

  included do
    rescue_from Pundit::NotAuthorizedError,
                with: ->(e) { log_error(e) && render_api_error(ApiError::NotAuthorizedError.new) }

    rescue_from ActionController::ParameterMissing,
                with: ->(e) { log_error(e) && render_api_error(ApiError::ParamMissingError.new(e.param)) }

    rescue_from ActiveRecord::RecordNotFound,
                with: ->(e) { log_error(e) && render_api_error(ApiError::NotFoundError.new) }

    rescue_from ActiveRecord::RecordInvalid,
                ActiveRecord::RecordNotDestroyed,
                with: ->(e) { log_error(e) && render_api_error(ApiError::RecordInvalidError.new(e.record.errors)) }

    rescue_from ApiError::StandardError,
                with: ->(e) { log_error(e) && render_api_error(e) }
  end

  private

  def log_error(error)
    Rails.logger.error(error)
  end

  def render_api_error(error)
    (error.headers || {}).each { |name, value| response.set_header(name, value) }
    render json: error, status: error.status
  end
end
