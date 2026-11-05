FactoryBot.define do
  factory :replay_run do
    project
    association :actor, factory: :user
    mode { ReplayRun::MODE_SINGLE }
    requested_count { 1 }
    materialized_at { Time.current }

    trait :bulk do
      mode { ReplayRun::MODE_BULK }
      requested_count { 0 }
      materialized_at { nil }
    end
  end

  factory :replay_item do
    message
    replay_run { association(:replay_run, project: message.endpoint.project) }
    endpoint { message.endpoint }
    status { ReplayItem::QUEUED_STATUS }
  end
end
