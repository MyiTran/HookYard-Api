# == Schema Information
#
# Table name: user_identities
#
#  id                :uuid             not null, primary key
#  email_at_provider :string           not null
#  provider          :string           not null
#  uid               :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :uuid             not null
#
# Indexes
#
#  index_user_identities_on_provider_and_uid      (provider,uid) UNIQUE
#  index_user_identities_on_user_id               (user_id)
#  index_user_identities_on_user_id_and_provider  (user_id,provider) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class UserIdentity < ApplicationRecord
  GOOGLE_PROVIDER = 'google'.freeze

  belongs_to :user

  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }
  validates :email_at_provider, presence: true
  validates :provider, uniqueness: { scope: :user_id }
end
