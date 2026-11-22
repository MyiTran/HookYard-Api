require 'rails_helper'

describe Authentication::GoogleTokenVerifier do
  let(:client_id) { 'google-client-id' }
  let(:claims) do
    {
      'sub' => 'google-subject',
      'email' => 'verified@example.com',
      'email_verified' => true
    }
  end

  before do
    allow(ENV).to receive(:fetch).with('GOOGLE_CLIENT_ID').and_return(client_id)
  end

  describe '#verify' do
    it 'uses Google OIDC verification with the configured audience and accepted issuers' do
      expect(Google::Auth::IDTokens).to receive(:verify_oidc).with(
        'id-token', aud: client_id, iss: Authentication::GoogleTokenVerifier::ISSUERS
      ).and_return(claims)

      expect(described_class.new.verify('id-token')).to eq(claims)
    end

    it 'rejects a missing credential with a bad request response' do
      expect { described_class.new.verify(nil) }.to raise_error(ApiError::GoogleAuthenticationError) { |error|
        expect(error.status).to eq(400)
        expect(error.code).to eq('google_credential_missing')
      }
    end

    %w[invalid-signature expired-token wrong-audience wrong-issuer].each do |failure|
      it "rejects a #{failure} without exposing verification details" do
        allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_raise(StandardError, failure)

        expect { described_class.new.verify('id-token') }.to raise_error(ApiError::GoogleAuthenticationError) { |error|
          expect(error.status).to eq(401)
          expect(error.code).to eq('google_authentication_failed')
        }
      end
    end

    it 'rejects an unverified email claim' do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_return(claims.merge('email_verified' => false))

      expect { described_class.new.verify('id-token') }.to raise_error(ApiError::GoogleAuthenticationError) { |error|
        expect(error.status).to eq(403)
        expect(error.code).to eq('google_email_unverified')
      }
    end

    %w[sub email].each do |missing_claim|
      it "rejects a token without #{missing_claim}" do
        allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_return(claims.except(missing_claim))

        expect { described_class.new.verify('id-token') }.to raise_error(ApiError::GoogleAuthenticationError) { |error|
          expect(error.status).to eq(401)
          expect(error.code).to eq('google_authentication_failed')
        }
      end
    end

    it 'fails safely when Google client configuration is absent' do
      allow(ENV).to receive(:fetch).with('GOOGLE_CLIENT_ID').and_raise(KeyError)

      expect { described_class.new.verify('id-token') }.to raise_error(ApiError::GoogleAuthenticationError) { |error|
        expect(error.status).to eq(500)
        expect(error.code).to eq('google_authentication_unavailable')
      }
    end
  end
end
