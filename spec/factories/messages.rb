FactoryBot.define do
  factory :message do
    transient do
      project { association(:project) }
    end

    event { association(:event, project: project) }
    endpoint { association(:endpoint, project: project) }
  end
end
