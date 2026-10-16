module Endpoints
  class Create < ApplicationOperation
    def call(project:, attributes:)
      Endpoint.transaction do
        endpoint = project.endpoints.create!(attributes)
        endpoint.rotate_signing_secret!
        endpoint
      end
    end
  end
end
