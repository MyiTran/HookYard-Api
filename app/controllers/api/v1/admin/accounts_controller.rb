module Api
  module V1
    module Admin
      class AccountsController < BaseController
        def show
          account = User.includes(:roles, :owned_projects).find(params[:id])

          render_resource(account, serializer: ::Admin::SupportAccountSerializer, view: :detail)
        end

        def plan
          account = User.find(params[:id])
          ensure_customer_account!(account)
          account = ::Users::ChangePlan.call(user: account, plan: plan_param)

          render_resource(account, serializer: ::Admin::SupportAccountSerializer)
        end

        private

        def ensure_customer_account!(account)
          return unless account.admin?

          raise ApiError::UnprocessableEntityError.new(
            message: 'Admin accounts cannot be changed through the customer plan endpoint'
          )
        end

        def plan_param
          params.require(:plan)
        end
      end
    end
  end
end
