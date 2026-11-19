# == Schema Information
#
# Table name: replay_runs
#
#  id              :uuid             not null, primary key
#  as_of           :datetime
#  failed_at       :datetime
#  failure_reason  :string
#  filters         :jsonb            not null
#  materialized_at :datetime
#  mode            :string           default("single"), not null
#  requested_count :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  actor_id        :uuid             not null
#  project_id      :uuid             not null
#
# Indexes
#
#  index_replay_runs_on_actor_id                   (actor_id)
#  index_replay_runs_on_project_id                 (project_id)
#  index_replay_runs_on_project_id_and_created_at  (project_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class ReplayRun < ApplicationRecord
  MODE_SINGLE = 'single'
  MODE_BULK = 'bulk'
  MODES = [MODE_SINGLE, MODE_BULK].freeze

  STATUS_QUEUED = 'queued'
  STATUS_RUNNING = 'running'
  STATUS_COMPLETED = 'completed'
  STATUS_FAILED = 'failed'

  FAILURE_REASON_QUOTA = 'monthly_delivery_limit_exceeded'
  FAILURE_REASON_OVER_LIMIT = 'bulk_replay_limit_exceeded'
  FAILURE_REASONS = [FAILURE_REASON_QUOTA, FAILURE_REASON_OVER_LIMIT].freeze

  FILTER_KEYS = %w[q message_id request_id endpoint_id event_type from to order].freeze

  belongs_to :project
  belongs_to :actor, class_name: 'User'
  has_many :replay_items, dependent: :destroy

  validates :mode, inclusion: { in: MODES }
  validates :requested_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_reason, inclusion: { in: FAILURE_REASONS }, allow_nil: true

  def self.normalized_filters(filters)
    filters.to_h.stringify_keys.slice(*FILTER_KEYS).compact_blank
  end

  def progress
    @progress ||= build_progress
  end

  def failed?
    failed_at.present?
  end

  def fail!(reason:, at: Time.current)
    update!(failed_at: at, failure_reason: reason)
  end

  private

  def build_progress
    counts = replay_items.group(:status).count
    eligible = counts.slice(*ReplayItem::STATUSES.keys.map(&:to_s)).values.sum

    {
      status: run_status(counts),
      summary: {
        requested: requested_count,
        eligible: eligible,
        blocked: requested_count - eligible,
        queued: counts.fetch(ReplayItem::QUEUED_STATUS, 0),
        held: counts.fetch(ReplayItem::HELD_STATUS, 0),
        delivering: counts.fetch(ReplayItem::DELIVERING_STATUS, 0),
        succeeded: counts.fetch(ReplayItem::SUCCEEDED_STATUS, 0),
        failed: counts.fetch(ReplayItem::FAILED_STATUS, 0),
        skipped: counts.fetch(ReplayItem::SKIPPED_STATUS, 0)
      }
    }
  end

  def run_status(counts)
    return STATUS_FAILED if failed_at.present?
    return STATUS_QUEUED if materialized_at.nil?

    counts.slice(*ReplayItem::ACTIVE_STATUSES).empty? ? STATUS_COMPLETED : STATUS_RUNNING
  end
end
