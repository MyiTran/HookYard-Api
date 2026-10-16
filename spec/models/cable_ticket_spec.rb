require 'rails_helper'

describe CableTicket, type: :model do
  let(:user) { create(:user) }

  describe '.issue!' do
    it 'creates a persisted ticket bound to the user with a token and a future expiry' do
      ticket = described_class.issue!(user)

      expect(ticket).to be_persisted
      expect(ticket.user).to eq(user)
      expect(ticket.token).to be_present
      expect(ticket.expires_at).to be > Time.current
      expect(ticket.used_at).to be_nil
    end
  end

  describe '.consume' do
    context 'with a valid unused ticket' do
      it 'returns the user and marks the ticket as used' do
        ticket = described_class.issue!(user)

        expect(described_class.consume(ticket.token)).to eq(user)
        expect(ticket.reload.used_at).to be_present
      end
    end

    context 'when the ticket has already been used' do
      it 'returns nil' do
        ticket = described_class.issue!(user)
        described_class.consume(ticket.token)

        expect(described_class.consume(ticket.token)).to be_nil
      end
    end

    context 'when the ticket has expired' do
      it 'returns nil' do
        ticket = described_class.issue!(user)
        ticket.update!(expires_at: 1.minute.ago)

        expect(described_class.consume(ticket.token)).to be_nil
      end
    end

    context 'when the token is unknown' do
      it 'returns nil' do
        expect(described_class.consume('unknown-token')).to be_nil
      end
    end

    context 'when the token is blank' do
      it 'returns nil' do
        expect(described_class.consume(nil)).to be_nil
      end
    end
  end
end
