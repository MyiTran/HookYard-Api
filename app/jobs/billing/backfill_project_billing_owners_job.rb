module Billing
  class BackfillProjectBillingOwnersJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 500
    MAX_BATCHES = 100
    SAMPLE_LIMIT = 10

    class IncompleteError < StandardError; end

    def perform(last_id = nil, batch_number = 0, batch_size = BATCH_SIZE)
      project_ids = pending_project_ids(last_id, batch_size)
      return if project_ids.empty?

      owner_rows = owner_memberships_for(project_ids)
      ambiguous_ids, owner_by_project = partition_owner_rows(owner_rows)
      owner_project_ids = owner_rows.map { |row| row['project_id'] }
      missing_ids = project_ids - owner_project_ids

      updated = set_billing_owners(owner_by_project)
      report = build_report(updated, missing_ids, ambiguous_ids)
      log_report(report)

      raise IncompleteError, incomplete_message(report) if incomplete?(report)

      enqueue_next(project_ids.last, batch_number, batch_size) if project_ids.size == batch_size
    end

    private

    def pending_project_ids(last_id, batch_size)
      scope = Project.where(billing_owner_id: nil).order(:id).limit(batch_size)
      scope = scope.where('projects.id > ?', last_id) if last_id
      scope.pluck(:id)
    end

    def owner_memberships_for(project_ids)
      ApplicationRecord.connection.select_all(<<~SQL.squish)
        SELECT project_id, COUNT(*) AS owner_count, MIN(user_id::text) AS user_id
        FROM project_memberships
        WHERE project_id IN (#{quoted_uuids(project_ids)})
          AND role = 'owner'
        GROUP BY project_id
      SQL
    end

    def partition_owner_rows(owner_rows)
      ambiguous_ids = []
      owner_by_project = {}

      owner_rows.each do |row|
        if row['owner_count'].to_i > 1
          ambiguous_ids << row['project_id']
        else
          owner_by_project[row['project_id']] = row['user_id']
        end
      end

      [ambiguous_ids, owner_by_project]
    end

    def set_billing_owners(owner_by_project)
      return 0 if owner_by_project.empty?

      project_ids = owner_by_project.keys
      user_ids = project_ids.map { |project_id| owner_by_project[project_id] }

      ApplicationRecord.connection.exec_update(<<~SQL.squish, 'BackfillProjectBillingOwnersJob')
        UPDATE projects
        SET billing_owner_id = owner_mapping.user_id
        FROM (
          SELECT
            unnest(ARRAY[#{quoted_uuids(project_ids)}]::uuid[]) AS project_id,
            unnest(ARRAY[#{quoted_uuids(user_ids)}]::uuid[]) AS user_id
        ) AS owner_mapping
        WHERE projects.id = owner_mapping.project_id
          AND projects.billing_owner_id IS NULL
      SQL
    end

    def build_report(updated, missing_ids, ambiguous_ids)
      {
        updated: updated,
        missing_owner: missing_ids.size,
        ambiguous_owner: ambiguous_ids.size,
        missing_owner_sample: missing_ids.first(SAMPLE_LIMIT),
        ambiguous_owner_sample: ambiguous_ids.first(SAMPLE_LIMIT)
      }
    end

    def log_report(report)
      Rails.logger.info(
        "billing_owner backfill batch: updated=#{report[:updated]} " \
        "missing_owner=#{report[:missing_owner]} ambiguous_owner=#{report[:ambiguous_owner]}"
      )
      Rails.logger.error("missing_owner samples: #{report[:missing_owner_sample].join(', ')}") if report[:missing_owner_sample].any?
      Rails.logger.error("ambiguous_owner samples: #{report[:ambiguous_owner_sample].join(', ')}") if report[:ambiguous_owner_sample].any?
    end

    def incomplete?(report)
      report[:missing_owner].positive? || report[:ambiguous_owner].positive?
    end

    def incomplete_message(report)
      "billing_owner backfill incomplete: missing_owner=#{report[:missing_owner]} " \
        "ambiguous_owner=#{report[:ambiguous_owner]}"
    end

    def enqueue_next(last_id, batch_number, batch_size)
      if batch_number + 1 >= MAX_BATCHES
        remaining = Project.where(billing_owner_id: nil).where('projects.id > ?', last_id).count
        if remaining.positive?
          Rails.logger.warn(
            "billing_owner backfill stopped at MAX_BATCHES=#{MAX_BATCHES}; " \
            "#{remaining} projects with billing_owner_id IS NULL may remain; " \
            're-run `rails data_backfills:enqueue_plan_backfills` to continue'
          )
        end
        return
      end

      self.class.perform_later(last_id, batch_number + 1, batch_size)
    end

    def quoted_uuids(ids)
      ids.map { |id| ApplicationRecord.connection.quote(id) }.join(', ')
    end
  end
end
