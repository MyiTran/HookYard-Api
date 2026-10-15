module Api
  module V1
    module Projects
      class InvitationsController < Api::V1::BaseController
        before_action :set_project

        def index
          authorize ProjectInvitation.new(project: @project)

          render_resource_collection(@project.project_invitations.pending.includes(:invited_by, :recipient),
                                     each_serializer: ProjectInvitationSerializer)
        end

        def create
          authorize ProjectInvitation.new(project: @project)
          invitation = ProjectInvitations::Create.call(project: @project, invited_by: current_user, email: invitation_params[:email])

          render_resource(invitation, status: :created)
        end

        def destroy
          invitation = @project.project_invitations.find(params[:id])
          authorize invitation
          ProjectInvitations::Cancel.call(invitation: invitation)

          head :no_content
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def invitation_params
          params.require(:invitation).permit(:email)
        end
      end
    end
  end
end
