module Api
  module V1
    module Admin
      class DeliveriesController < BaseController
        def index
          scope = ::Admin::DeliveriesQuery.call(Message.all, **query_params)
          pagy, deliveries = paginate(scope)

          render_resource_collection(deliveries, each_serializer: ::Admin::DeliverySerializer, pagy: pagy)
        end

        private

        def query_params
          params.permit(:account_id, :status, :failure_category, :project_id, :endpoint_id, :from, :to, :order)
                .to_h.symbolize_keys
        end
      end
    end
  end
end
