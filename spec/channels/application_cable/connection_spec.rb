require 'rails_helper'

describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user) }

  describe '#connect' do
    context 'with a valid cable ticket' do
      it 'identifies the current user' do
        ticket = CableTicket.issue!(user)

        connect params: { ticket: ticket.token }

        expect(connection.current_user).to eq(user)
      end
    end

    context 'without a cable ticket' do
      it 'rejects the connection' do
        expect { connect }.to have_rejected_connection
      end
    end

    context 'with an unknown cable ticket' do
      it 'rejects the connection' do
        expect { connect params: { ticket: 'unknown-token' } }.to have_rejected_connection
      end
    end

    context 'when the cable ticket has expired' do
      it 'rejects the connection' do
        ticket = CableTicket.issue!(user)
        ticket.update!(expires_at: 1.minute.ago)

        expect { connect params: { ticket: ticket.token } }.to have_rejected_connection
      end
    end

    context 'when the cable ticket has already been used' do
      it 'rejects the connection' do
        ticket = CableTicket.issue!(user)
        CableTicket.consume(ticket.token)

        expect { connect params: { ticket: ticket.token } }.to have_rejected_connection
      end
    end
  end
end
