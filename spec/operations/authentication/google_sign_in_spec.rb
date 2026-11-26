require 'rails_helper'

describe Authentication::GoogleSignIn do
  let(:claims) do
    {
      'sub' => 'google-subject',
      'email' => 'verified@example.com',
      'email_verified' => true,
      'given_name' => 'Verified',
      'family_name' => 'User'
    }
  end

  describe '#call' do
    it 'signs in the user already linked to the Google subject' do
      identity = create(:user_identity, uid: claims['sub'])

      expect(described_class.call(claims:)).to eq(identity.user)
    end

    it 'does not reassign an existing Google subject based on another email claim' do
      identity = create(:user_identity, uid: claims['sub'])

      expect(described_class.call(claims: claims.merge('email' => 'other@example.com'))).to eq(identity.user)
    end

    it 'links a confirmed local account with the verified email' do
      user = create(:user, email: claims['email'])

      expect { described_class.call(claims:) }.to change(UserIdentity, :count).by(1)
      expect(user.user_identities.find_by!(provider: UserIdentity::GOOGLE_PROVIDER).uid).to eq(claims['sub'])
    end

    it 'links the existing confirmed account after email normalization' do
      user = create(:user, email: 'Existing@Example.com')

      described_class.call(claims: claims.merge('email' => ' EXISTING@example.com '))

      expect(user.user_identities.find_by!(provider: UserIdentity::GOOGLE_PROVIDER).uid).to eq(claims['sub'])
    end

    it 'does not change an existing account role or plan while linking' do
      user = create(:user, :pro, email: claims['email'])
      user.add_role(:admin)

      described_class.call(claims:)

      expect(user.reload.plan).to eq(User::PRO_PLAN)
      expect(user.has_role?(:admin)).to be(true)
    end

    it 'rolls back the new user when identity creation fails' do
      allow_any_instance_of(UserIdentity).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(UserIdentity.new))

      expect { described_class.call(claims:) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(User.find_by(email: claims['email'])).to be_nil
    end

    it 'does not link an unconfirmed local account' do
      create(:user, :need_confirmation, email: claims['email'])

      expect { described_class.call(claims:) }.to raise_error(ApiError::GoogleAuthenticationError) { |error|
        expect(error.status).to eq(409)
        expect(error.code).to eq('account_link_required')
      }
    end

    it 'creates a confirmed support user and a linked identity for a new verified email' do
      expect { described_class.call(claims:) }.to change(User, :count).by(1).and change(UserIdentity, :count).by(1)

      user = User.find_by!(email: claims['email'])
      expect(user).to be_confirmed
      expect(user.has_role?(:support)).to be(true)
      expect(user.user_identities.find_by!(provider: UserIdentity::GOOGLE_PROVIDER).email_at_provider).to eq(claims['email'])
    end
  end
end
