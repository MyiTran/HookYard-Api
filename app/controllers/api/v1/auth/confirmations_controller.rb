module API
  module V1
    module Auth
      class ConfirmationsController < Devise::ConfirmationsController
        respond_to :json

        def create
          self.resource = resource_class.send_confirmation_instructions(resource_params)
          render json: { message: I18n.t('devise.confirmations.send_paranoid_instructions') }
        end

        def update
          token = params[:confirmation_token] || params.dig(:confirmation, :confirmation_token)
          self.resource = resource_class.confirm_by_token(token)

          if resource.errors.empty?
            render json: { message: 'Your account has been confirmed successfully.' }
          else
            render json: { errors: resource.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
