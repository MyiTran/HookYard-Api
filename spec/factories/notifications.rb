FactoryBot.define do
  factory :notification do
    user
    kind { :project_invitation_received }
    title { 'Project invitation' }
    message { 'You were invited to a project' }
  end
end
