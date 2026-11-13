module Api
  module V1
    module Admin
      class AccountsController < BaseController
        def plan
          account = ::Users::ChangePlan.call(user: User.find(params[:id]), plan: plan_params)

          render_resource(account, serializer: AccountSerializer)
        end

        private

        def plan_params
          params.require(:account).permit(:plan)[:plan]
        end
      end
    end
  end
end
