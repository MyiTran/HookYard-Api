module Api
  module V1
    class AccountsController < BaseController
      def show
        render_resource(current_user, serializer: AccountSerializer)
      end

      def plan
        account = ::Users::ChangePlan.call(user: current_user, plan: plan_params)

        render_resource(account, serializer: AccountSerializer)
      end

      private

      def plan_params
        params.require(:account).permit(:plan)[:plan]
      end
    end
  end
end
