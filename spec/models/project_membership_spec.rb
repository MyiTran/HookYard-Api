require 'rails_helper'

describe ProjectMembership, type: :model do
  describe 'validations' do
    context 'when the user already belongs to the project' do
      it 'is invalid' do
        membership = create(:project_membership)
        duplicate = build(:project_membership, project: membership.project, user: membership.user)

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end
    end

    context 'when the project already has an owner' do
      let(:project) { create(:project) }

      before { create(:project_membership, project: project, role: :owner) }

      it 'rejects a second owner at the database level' do
        expect { create(:project_membership, project: project, role: :owner) }
          .to raise_error(ActiveRecord::RecordNotUnique)
      end

      it 'still allows a maintainer' do
        create(:project_membership, project: project, role: :maintainer)

        expect(project.project_memberships.pluck(:role).sort).to eq(%w[maintainer owner])
      end
    end
  end
end
