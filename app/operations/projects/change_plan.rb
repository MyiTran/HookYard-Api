module Projects
  class ChangePlan < ApplicationOperation
    def call(project:, plan:)
      project.update!(plan: plan)
      project
    end
  end
end
