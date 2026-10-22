class ProjectApiCredentialPolicy < ApplicationPolicy
  def index?
    owner?
  end

  def create?
    owner?
  end

  def revoke?
    owner?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? scope.where(project: user.projects) : scope.none
    end
  end

  private

  def owner?
    record.project.owner?(user)
  end
end
