class EndpointPolicy < ApplicationPolicy
  def index?
    member?
  end

  def show?
    member?
  end

  def create?
    owner?
  end

  def update?
    owner? && !record.archived?
  end

  def archive?
    owner?
  end

  def rotate_signing_secret?
    owner? && !record.archived?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? scope.where(project: user.projects) : scope.none
    end
  end

  private

  def member?
    record.project.member?(user)
  end

  def owner?
    record.project.owner?(user)
  end
end
