module Api
  module V1
    class NotificationsController < BaseController
      def index
        notifications = policy_scope(Notification).recent

        render_resource_collection(notifications.limit(20),
                                   each_serializer: NotificationSerializer,
                                   meta: { unread_count: notifications.unread.count })
      end

      def read
        notification = policy_scope(Notification).find(params[:id])
        authorize notification

        notification.update!(read_at: Time.current)

        render_resource(notification)
      end

      def read_all
        authorize Notification

        policy_scope(Notification).unread.update_all(read_at: Time.current)

        head :no_content
      end
    end
  end
end
