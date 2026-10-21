class EndpointMessagesQuery < ApplicationQuery
  include MessageAttemptSummary

  def call(scope = Message.none, **)
    apply_order(with_attempt_summary(scope).preload(:event))
  end

  private

  def apply_order(scope)
    scope.order('messages.created_at DESC, messages.id DESC')
  end
end
