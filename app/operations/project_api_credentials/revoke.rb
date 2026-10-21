module ProjectApiCredentials
  class Revoke < ApplicationOperation
    def call(credential:)
      credential.revoke!
    end
  end
end
