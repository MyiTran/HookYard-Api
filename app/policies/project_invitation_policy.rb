class ProjectInvitationPolicy < ApplicationPolicy
  def index?
    owner?
  end

  def create?
    owner?
  end

  def destroy?
    owner?
  end

  def accept?
    record.recipient_id == user.id
  end

  def decline?
    record.recipient_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? scope.where(recipient_id: user.id) : scope.none
    end
  end

  private

  def owner?
    record.project.owner?(user)
  end
end
