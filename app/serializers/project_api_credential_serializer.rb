class ProjectApiCredentialSerializer < ApplicationSerializer
  identifier :id

  fields :name, :token_hint, :revoked_at, :created_at

  view :with_token do
    field :token do |_credential, options|
      options[:token]
    end
  end
end
