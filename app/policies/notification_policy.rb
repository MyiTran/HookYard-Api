class NotificationPolicy < ApplicationPolicy
  def read?
    record.user_id == user.id
  end

  def read_all?
    true
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user ? scope.where(user_id: user.id) : scope.none
    end
  end
end
