require 'rails_helper'

describe Projects::Create, type: :operation do
  let(:user) { create(:user) }

  describe '.call' do
    it 'creates the project and its owner membership' do
      project = described_class.call(user: user, attributes: { name: 'Alpha' })

      expect(project.project_memberships.pluck(:user_id, :role)).to eq([[user.id, 'owner']])
    end

    it 'rolls back the project when owner membership creation fails' do
      allow_any_instance_of(ProjectMembership).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(ProjectMembership.new))

      expect { described_class.call(user: user, attributes: { name: 'Alpha' }) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(Project.count).to eq(0)
    end
  end
end
