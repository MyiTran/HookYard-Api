require 'swagger_helper'

describe 'Notifications', type: :request do
  let(:user) { create(:user) }
  let(:other) { create(:user) }

  describe 'GET /api/v1/notifications' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/notifications'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated' do
      it 'returns only the current user notifications, newest first' do
        older = create(:notification, user: user, created_at: 2.days.ago)
        newer = create(:notification, user: user, created_at: 1.day.ago)
        create(:notification, user: other)

        get '/api/v1/notifications', headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(json_response['data'].map { |entry| entry['id'] }).to eq([newer.id, older.id])
      end

      it 'excludes notifications older than 30 days' do
        recent = create(:notification, user: user, created_at: 1.day.ago)
        create(:notification, user: user, created_at: 31.days.ago)

        get '/api/v1/notifications', headers: auth_headers(user)

        expect(json_response['data'].map { |entry| entry['id'] }).to eq([recent.id])
      end

      it 'returns at most 20 notifications' do
        create_list(:notification, 21, user: user)

        get '/api/v1/notifications', headers: auth_headers(user)

        expect(json_response['data'].size).to eq(20)
      end

      it 'returns the unread count of the current user' do
        create(:notification, user: user)
        create(:notification, user: user, read_at: Time.current)
        create(:notification, user: other)

        get '/api/v1/notifications', headers: auth_headers(user)

        expect(json_response['meta']['unread_count']).to eq(1)
      end

      it 'serializes the frontend contract' do
        notification = create(:notification, user: user, kind: :project_invitation_received,
                                             target_url: '/projects')

        get '/api/v1/notifications', headers: auth_headers(user)

        expect(json_response['data'].first.keys).to include(
          'id', 'kind', 'title', 'message', 'target_url', 'read_at', 'created_at',
          'project_id', 'project_invitation_id'
        )
        expect(json_response['data'].first['id']).to eq(notification.id)
      end
    end
  end

  describe 'PATCH /api/v1/notifications/:id/read' do
    context 'when the notification belongs to the current user' do
      it 'marks the notification as read' do
        notification = create(:notification, user: user)

        patch "/api/v1/notifications/#{notification.id}/read", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(notification.reload.read_at).to be_present
      end

      it 'is idempotent' do
        notification = create(:notification, user: user, read_at: 1.hour.ago)

        patch "/api/v1/notifications/#{notification.id}/read", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(notification.reload.read_at).to be_present
      end
    end

    context 'when the notification belongs to another user' do
      it 'cannot be read' do
        notification = create(:notification, user: other)

        patch "/api/v1/notifications/#{notification.id}/read", headers: auth_headers(user)

        expect(response).to have_http_status(:not_found)
        expect(notification.reload.read_at).to be_nil
      end
    end
  end

  describe 'PATCH /api/v1/notifications/read_all' do
    it 'marks every unread notification of the current user as read' do
      create_list(:notification, 2, user: user)
      other_notification = create(:notification, user: other)

      patch '/api/v1/notifications/read_all', headers: auth_headers(user)

      expect(response).to have_http_status(:no_content)
      expect(user.notifications.unread).to be_empty
      expect(other_notification.reload.read_at).to be_nil
    end
  end
end
