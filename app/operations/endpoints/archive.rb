module Endpoints
  class Archive < ApplicationOperation
    def call(endpoint:)
      endpoint.update!(archived_at: Time.current) unless endpoint.archived?
      endpoint
    end
  end
end
