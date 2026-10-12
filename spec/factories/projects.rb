FactoryBot.define do
  factory :project do
    name { Faker::App.name }

    trait :with_owner do
      transient do
        owner { association(:user) }
      end

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
end
