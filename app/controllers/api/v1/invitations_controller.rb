module API
  module V1
    class InvitationsController < BaseController
      def index
        render_resource_collection(policy_scope(ProjectInvitation).pending.order(created_at: :desc),
                                   each_serializer: ProjectInvitationSerializer)
      end

      def accept
        invitation = policy_scope(ProjectInvitation).find(params[:id])
        authorize invitation, :accept?

        render_resource(ProjectInvitations::Accept.call(invitation: invitation))
      end
    end
  end
end
