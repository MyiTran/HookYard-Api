module Endpoints
  class RotateSigningSecret < ApplicationOperation
    def call(endpoint:)
      endpoint.rotate_signing_secret!
    end
  end
end
