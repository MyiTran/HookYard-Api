# == Schema Information
#
# Table name: cable_tickets
#
#  id         :uuid             not null, primary key
#  expires_at :datetime         not null
#  token      :string           not null
#  used_at    :datetime
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :uuid             not null
#
# Indexes
#
#  index_cable_tickets_on_expires_at  (expires_at)
#  index_cable_tickets_on_token       (token) UNIQUE
#  index_cable_tickets_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class CableTicket < ApplicationRecord
  TTL = 60.seconds

  belongs_to :user

  def self.issue!(user)
    create!(user: user, token: SecureRandom.urlsafe_base64(32), expires_at: TTL.from_now)
  end

  def self.consume(raw_token)
    return nil if raw_token.blank?

    transaction do
      ticket = lock.find_by(token: raw_token)
      next nil if ticket.nil? || ticket.used_at.present? || ticket.expires_at <= Time.current

      ticket.update!(used_at: Time.current)
      ticket.user
    end
  end
end
