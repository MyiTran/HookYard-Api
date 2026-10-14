class AddDeclinedAtToProjectInvitations < ActiveRecord::Migration[8.0]
  def change
    add_column :project_invitations, :declined_at, :datetime
  end
end
