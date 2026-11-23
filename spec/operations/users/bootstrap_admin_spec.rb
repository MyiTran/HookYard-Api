require 'rails_helper'

describe Users::BootstrapAdmin do
  let(:email) { 'admin@example.test' }
  let(:password) { 'a-strong-password' }

  describe '.call' do
    it 'creates and confirms the first administrator' do
      user = described_class.call(email:, password:)

      expect(user).to be_persisted
      expect(user.email).to eq(email)
      expect(user).to be_confirmed
      expect(user).to be_admin
    end

    it 'returns the existing administrator for the same normalized email' do
      existing_admin = create(:user, email: email).tap { |user| user.add_role(:admin) }

      result = described_class.call(email: "  #{email.upcase}  ", password:)

      expect(result).to eq(existing_admin)
      expect(User.where('LOWER(email) = ?', email).count).to eq(1)
    end

    it 'rejects missing credentials' do
      expect { described_class.call(email: ' ', password: password) }
        .to raise_error(Users::BootstrapAdmin::MissingCredentialsError)
      expect { described_class.call(email: email, password: ' ') }
        .to raise_error(Users::BootstrapAdmin::MissingCredentialsError)
    end

    it 'does not elevate an existing non-administrator without an explicit override' do
      create(:user, email: email)

      expect { described_class.call(email:, password:) }
        .to raise_error(Users::BootstrapAdmin::ExistingUserConflictError)
    end

    it 'does not create another administrator while a different administrator exists' do
      create(:user).add_role(:admin)

      expect { described_class.call(email:, password:) }
        .to raise_error(Users::BootstrapAdmin::ExistingAdministratorConflictError)
    end
  end
end
