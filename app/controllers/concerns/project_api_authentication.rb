module ProjectApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_project!
  end

  private

  attr_reader :current_project

  def authenticate_project!
    @current_project = ProjectApiCredential.authenticate(bearer_token)&.project
    raise ApiError::NotAuthenticatedError if @current_project.nil?
  end

  def bearer_token
    scheme, token = request.headers['Authorization'].to_s.split(' ', 2)
    token if scheme.to_s.casecmp('bearer').zero?
  end
end
