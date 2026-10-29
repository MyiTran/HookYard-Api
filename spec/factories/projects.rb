FactoryBot.define do
  factory :project do
    transient do
      owner { association(:user) }
    end

    name { Faker::App.name }
    billing_owner { owner }

    trait :pro do
      transient do
        owner { association(:user, :pro) }
      end
    end

    trait :with_owner do
      after(:create) do |project, evaluator|
        create(:project_membership, project: project, user: evaluator.owner, role: :owner)
      end
    end
  end

  factory :project_membership do
    project
    user
    role { :maintainer }
  end

  factory :project_invitation do
    project
    association :invited_by, factory: :user
    association :recipient, factory: :user
    role { :maintainer }
    status { :pending }
  end

  factory :endpoint do
    project
    name { Faker::App.name }
    url { Faker::Internet.url(scheme: 'https') }
    active { true }

    after(:create) do |endpoint|
      endpoint.rotate_signing_secret!
    end
  end
end
