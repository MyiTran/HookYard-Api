module Replays
  class DeliverJob < ApplicationJob
    queue_as :low
    sidekiq_options retry: false

    discard_on ActiveRecord::RecordNotFound

    def perform(replay_item_id)
      Replays::Deliver.call(item: ReplayItem.find(replay_item_id))
    end
  end
end
