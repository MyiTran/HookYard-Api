class MessagePolicy < ApplicationPolicy
  def show?
    member?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? scope.where(event_id: Event.where(project_id: user.projects).select(:id)) : scope.none
    end
  end

  private

  def member?
    record.event.project.member?(user)
  end
end
