class ProjectPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    member?
  end

  def create?
    true
  end

  def update?
    owner?
  end

  def change_plan?
    owner?
  end

  def destroy?
    owner?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? user.projects : scope.none
    end
  end

  private

  def member?
    record.member?(user)
  end

  def owner?
    record.owner?(user)
  end
end
