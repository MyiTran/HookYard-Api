require 'rails_helper'

describe CableTicket do
  let(:user) { create(:user) }

  describe '.issue!' do
    it 'creates a ticket for the user with a token and a future expiry' do
      ticket = described_class.issue!(user)

      expect(ticket).to be_persisted
      expect(ticket.user).to eq(user)
      expect(ticket.token).to be_present
      expect(ticket.expires_at).to be > Time.current
      expect(ticket.used_at).to be_nil
    end
  end

  describe '.consume' do
    it 'returns the user and marks the ticket as used' do
      ticket = described_class.issue!(user)

      expect(described_class.consume(ticket.token)).to eq(user)
      expect(ticket.reload.used_at).to be_present
    end

    it 'cannot be consumed twice' do
      ticket = described_class.issue!(user)
      described_class.consume(ticket.token)

      expect(described_class.consume(ticket.token)).to be_nil
    end

    it 'returns nil for an expired ticket' do
      ticket = described_class.issue!(user)
      ticket.update!(expires_at: 1.minute.ago)

      expect(described_class.consume(ticket.token)).to be_nil
    end

    it 'returns nil for an unknown token' do
      expect(described_class.consume('unknown-token')).to be_nil
    end

    it 'returns nil for a blank token' do
      expect(described_class.consume(nil)).to be_nil
    end
  end
end
