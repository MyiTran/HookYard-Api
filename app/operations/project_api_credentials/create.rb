module ProjectApiCredentials
  class Create < ApplicationOperation
    def call(project:, name:)
      ProjectApiCredential.create_with_token!(project: project, name: name)
    end
  end
end
