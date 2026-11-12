FactoryBot.define do
  factory :delivery_metric do
    project
    day { Date.current }
    attempts_count { 0 }
    successes_count { 0 }
    failures_count { 0 }
  end
end
