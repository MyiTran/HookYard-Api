class NotificationsChannel < ApplicationCable::Channel
  def self.broadcast_created(notification)
    broadcast_to(notification.user, { type: 'notification.created' })
  end

  def self.broadcast_removed(user)
    broadcast_to(user, { type: 'notification.removed' })
  end

  def subscribed
    stream_for current_user
  end
end
