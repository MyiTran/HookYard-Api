class ProjectSerializer < ApplicationSerializer
  identifier :id

  fields :name, :created_at, :updated_at

  field :current_user_role do |project, options|
    project.project_memberships.find_by(user_id: options[:current_user]&.id)&.role
  end
end
