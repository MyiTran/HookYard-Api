class ProjectMembershipPolicy < ApplicationPolicy
  def destroy?
    record.project.owner?(user) && !record.owner?
  end
end
