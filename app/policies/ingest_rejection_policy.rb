class IngestRejectionPolicy < ApplicationPolicy
  def index?
    member?
  end

  def show?
    member?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? scope.where(project_id: user.projects.select(:id)) : scope.none
    end
  end

  private

  def member?
    record.project.member?(user)
  end
end
