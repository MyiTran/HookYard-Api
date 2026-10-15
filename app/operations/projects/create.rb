module Projects
  class Create < ApplicationOperation
    def call(user:, attributes:)
      Project.transaction do
        project = Project.create!(attributes)
        project.project_memberships.create!(user: user, role: :owner)
        project
      end
    end
  end
end
