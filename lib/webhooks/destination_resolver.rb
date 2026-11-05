require 'ipaddr'
require 'resolv'
require 'timeout'

module Webhooks
  # Resolves a validated webhook host to one pinned public IP address.
  # Pinning prevents a hostname from changing to an unsafe address at request time.
  # Policy rejections (NotPubliclyRoutable) are permanent, while DNS failures
  # (ResolutionFailed) are transient and must stay retryable.
  class DestinationResolver
    class NotPubliclyRoutable < StandardError; end
    class ResolutionFailed < StandardError; end

    NOT_ROUTABLE_MESSAGE = 'destination is not publicly routable'
    RESOLUTION_FAILED_MESSAGE = 'destination resolution failed'

    def initialize(timeout: Constants::WEBHOOK_DNS_RESOLUTION_TIMEOUT_SECONDS)
      @timeout = timeout
    end

    def resolve(uri)
      host = uri.host.to_s
      raise NotPubliclyRoutable, NOT_ROUTABLE_MESSAGE unless DestinationPolicy.public_host?(host)

      address = pinned_address(uri.hostname.to_s)
      raise NotPubliclyRoutable, NOT_ROUTABLE_MESSAGE unless DestinationPolicy.public_ip?(address)

      address.to_s
    end

    private

    attr_reader :timeout

    def pinned_address(hostname)
      literal = parse_ip(hostname)
      return literal if literal

      addresses = resolve_addresses(hostname)
      raise ResolutionFailed, RESOLUTION_FAILED_MESSAGE if addresses.empty?
      raise NotPubliclyRoutable, NOT_ROUTABLE_MESSAGE unless addresses.all? { |address| DestinationPolicy.public_ip?(address) }

      addresses.first
    end

    def resolve_addresses(hostname)
      Timeout.timeout(timeout) { Resolv.getaddresses(hostname).filter_map { |address| parse_ip(address) } }
    rescue Timeout::Error, Resolv::ResolvError, SocketError
      raise ResolutionFailed, RESOLUTION_FAILED_MESSAGE
    end

    def parse_ip(value)
      IPAddr.new(value.to_s)
    rescue IPAddr::Error
      nil
    end
  end
end
