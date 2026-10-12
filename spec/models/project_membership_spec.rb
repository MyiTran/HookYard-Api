require 'rails_helper'

describe ProjectMembership do
  describe 'uniqueness' do
    it 'forbids a duplicate membership for the same user and project' do
      membership = create(:project_membership)
      duplicate = build(:project_membership, project: membership.project, user: membership.user)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end
  end

  describe 'owner uniqueness' do
    let(:project) { create(:project) }

    it 'allows at most one owner per project' do
      create(:project_membership, project: project, role: :owner)

      expect { create(:project_membership, project: project, role: :owner) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows a maintainer alongside the owner' do
      create(:project_membership, project: project, role: :owner)
      create(:project_membership, project: project, role: :maintainer)

      expect(project.project_memberships.pluck(:role).sort).to eq(%w[maintainer owner])
    end
  end
end
