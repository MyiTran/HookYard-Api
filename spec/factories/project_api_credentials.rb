FactoryBot.define do
  factory :project_api_credential do
    transient do
      raw_token { ProjectApiCredential.generate_token }
    end

    project
    name { Faker::App.name }
    token_digest { ProjectApiCredential.digest_for(raw_token) }
    token_hint { raw_token.first(ProjectApiCredential::TOKEN_HINT_LENGTH) }
  end
end
