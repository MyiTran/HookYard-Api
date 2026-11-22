class EndpointMessagesQuery < ApplicationQuery
  include MessageAttemptSummary

  def call(scope = Message.none, **)
    apply_order(
      with_attempt_summary(scope).preload(
        *MessagesQuery.preload_associations(preload_replay_items: true, preload_endpoint_context: false)
      )
    )
  end

  private

  def apply_order(scope)
    scope.order('messages.created_at DESC, messages.id DESC')
  end
end
