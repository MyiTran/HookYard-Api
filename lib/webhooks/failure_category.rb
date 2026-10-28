module Webhooks
  # Maps stored delivery evidence to a stable, client-facing failure category.
  # The category never contains resolved addresses, resolver internals or class
  # names, so the API can explain a failure without leaking infrastructure detail.
  module FailureCategory
    DESTINATION_REJECTED = 'destination_rejected'
    TIMEOUT = 'timeout'
    NETWORK = 'network'
    HTTP_ERROR = 'http_error'
    INTERRUPTED = 'interrupted'

    DESTINATION_REJECTION_TYPES = %w[Webhooks::DestinationResolver::NotPubliclyRoutable].freeze
    TIMEOUT_ERROR_TYPES = %w[
      Timeout::Error
      Net::OpenTimeout
      Net::ReadTimeout
      Net::WriteTimeout
      Errno::ETIMEDOUT
    ].freeze
    INTERRUPTED_ERROR_TYPES = %w[DeliveryLeaseExpired].freeze

    module_function

    def for(error_type: nil, response_status: nil)
      type = error_type.to_s

      return DESTINATION_REJECTED if DESTINATION_REJECTION_TYPES.include?(type)
      return INTERRUPTED if INTERRUPTED_ERROR_TYPES.include?(type)
      return TIMEOUT if TIMEOUT_ERROR_TYPES.include?(type)
      return NETWORK if type.present?
      return HTTP_ERROR if response_status.present?

      nil
    end
  end
end
