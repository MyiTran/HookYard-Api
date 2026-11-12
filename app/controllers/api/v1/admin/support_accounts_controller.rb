module Api
  module V1
    module Admin
      class SupportAccountsController < BaseController
        def index
          scope = ::Admin::SupportAccountsQuery.call(User.all, **query_params)
          pagy, accounts = paginate(scope)

          render_resource_collection(accounts, each_serializer: ::Admin::SupportAccountSerializer, pagy: pagy)
        end

        private

        def query_params
          params.permit(:q, :role, :plan, :active, :order).to_h.symbolize_keys
        end
      end
    end
  end
end
