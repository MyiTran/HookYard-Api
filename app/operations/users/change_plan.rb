module Users
  class ChangePlan < ApplicationOperation
    ADMIN_PLAN_CHANGE_MESSAGE = 'System admin accounts cannot change subscription plans'

    def call(user:, plan:)
      raise ApiError::UnprocessableEntityError.new(
        message: ADMIN_PLAN_CHANGE_MESSAGE,
        errors: [{ field: 'plan', message: ADMIN_PLAN_CHANGE_MESSAGE }]
      ) if user.admin?

      user.update!(plan: plan)
      user
    end
  end
end
