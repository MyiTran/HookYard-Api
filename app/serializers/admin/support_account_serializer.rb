module Admin
  class SupportAccountSerializer < ApplicationSerializer
    identifier :id

    fields :email, :first_name, :last_name, :sign_in_count, :last_sign_in_at, :created_at

    field(:name) { |account| account.name }

    field(:plan) { |account| account.plan }

    field(:confirmed) { |account| account.confirmed_at.present? }

    field(:roles) { |account| account.roles.map(&:name) }

    view :detail do
      field(:owned_project_count) { |account| account.owned_projects.size }

      field(:owned_projects) do |account|
        account.owned_projects.map do |project|
          { id: project.id, name: project.name }
        end
      end
    end
  end
end
