class EndpointDiagnosisPolicy < ApplicationPolicy
  def create?
    member?
  end

  def show?
    member?
  end

  private

  def member?
    record.project.member?(user)
  end
end
