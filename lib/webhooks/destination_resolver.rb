require 'ipaddr'
require 'resolv'
require 'timeout'

module Webhooks
  class DestinationResolver
    class NotPubliclyRoutable < StandardError; end

    NOT_ROUTABLE_MESSAGE = 'destination is not publicly routable'

    def initialize(timeout: Constants::WEBHOOK_HTTP_TIMEOUT_SECONDS)
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
      raise NotPubliclyRoutable, NOT_ROUTABLE_MESSAGE if addresses.empty?
      raise NotPubliclyRoutable, NOT_ROUTABLE_MESSAGE unless addresses.all? { |address| DestinationPolicy.public_ip?(address) }

      addresses.first
    end

    def resolve_addresses(hostname)
      Timeout.timeout(timeout) { Resolv.getaddresses(hostname).filter_map { |address| parse_ip(address) } }
    rescue Timeout::Error, Resolv::ResolvError
      raise NotPubliclyRoutable, NOT_ROUTABLE_MESSAGE
    end

    def parse_ip(value)
      IPAddr.new(value.to_s)
    rescue IPAddr::Error
      nil
    end
  end
end
