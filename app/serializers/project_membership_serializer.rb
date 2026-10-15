class ProjectMembershipSerializer < ApplicationSerializer
  identifier :id

  field :role

  association :user, blueprint: UserSerializer
end
