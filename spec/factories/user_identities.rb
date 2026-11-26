FactoryBot.define do
  factory :user_identity do
    user
    provider { UserIdentity::GOOGLE_PROVIDER }
    sequence(:uid) { |number| "google-subject-#{number}" }
    email_at_provider { user.email }
  end
end
