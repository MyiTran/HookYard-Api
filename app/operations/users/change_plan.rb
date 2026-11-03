module Users
  class ChangePlan < ApplicationOperation
    def call(user:, plan:)
      user.update!(plan: plan)
      user
    end
  end
end
