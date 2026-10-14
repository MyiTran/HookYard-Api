require 'rails_helper'

describe ApplicationCable::Connection do
  let(:user) { create(:user) }

  it 'connects and identifies the user for a valid ticket' do
    ticket = CableTicket.issue!(user)

    connect params: { ticket: ticket.token }

    expect(connection.current_user).to eq(user)
  end

  it 'rejects a connection without a ticket' do
    expect { connect }.to have_rejected_connection
  end

  it 'rejects a connection with an unknown ticket' do
    expect { connect params: { ticket: 'unknown-token' } }.to have_rejected_connection
  end

  it 'rejects a connection with an expired ticket' do
    ticket = CableTicket.issue!(user)
    ticket.update!(expires_at: 1.minute.ago)

    expect { connect params: { ticket: ticket.token } }.to have_rejected_connection
  end

  it 'rejects a connection with an already used ticket' do
    ticket = CableTicket.issue!(user)
    CableTicket.consume(ticket.token)

    expect { connect params: { ticket: ticket.token } }.to have_rejected_connection
  end
end
