FactoryBot.define do
  factory :replay_run do
    project
    association :actor, factory: :user
    mode { ReplayRun::MODE_SINGLE }
    filters { {} }
    requested_count { 0 }
    materialized_at { Time.current }
  end

  factory :replay_item do
    replay_run
    message
    endpoint { message.endpoint }
    status { ReplayItem::QUEUED_STATUS }
  end
end
