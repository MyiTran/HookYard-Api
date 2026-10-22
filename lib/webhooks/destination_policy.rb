require 'ipaddr'

module Webhooks
  # Centralizes validation for public webhook destinations.
  # Rejects private, reserved, internal, and ambiguous host/IP forms.
  # Used before endpoint delivery and after DNS resolution.
  module DestinationPolicy
    INTERNAL_HOSTNAMES = %w[localhost localhost.localdomain ip6-localhost ip6-loopback].freeze
    INTERNAL_HOSTNAME_SUFFIXES = %w[.localhost .local .internal .localdomain .home.arpa .lan .corp .home].freeze
    PUBLIC_HOSTNAME = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

    NON_PUBLIC_IPV4_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
      198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ].map { |range| IPAddr.new(range) }.freeze

    NON_PUBLIC_IPV6_RANGES = %w[
      ::/128 ::1/128 64:ff9b::/96 100::/64 2001:db8::/32
      ::ffff:0:0/96 fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    module_function

    def public_host?(host)
      normalized_host = host.to_s.downcase.delete_suffix('.')
      return false if normalized_host.blank?
      return public_ip?(normalized_host[1..-2]) if bracketed_ipv6?(normalized_host)
      return public_ip?(normalized_host) if canonical_ipv4?(normalized_host)
      return false if ambiguous_numeric_host?(normalized_host)

      public_hostname?(normalized_host)
    end

    def public_ip?(value)
      address = value.is_a?(IPAddr) ? value : IPAddr.new(value.to_s)
      !non_public_ip?(address)
    rescue IPAddr::Error
      false
    end

    def bracketed_ipv6?(host)
      host.start_with?('[') && host.end_with?(']')
    end

    def canonical_ipv4?(host)
      labels = host.split('.')
      labels.size == 4 && labels.all? { |label| canonical_ipv4_label?(label) }
    end

    def canonical_ipv4_label?(label)
      label.match?(/\A(0|[1-9]\d{0,2})\z/) && label.to_i <= 255
    end

    def ambiguous_numeric_host?(host)
      host.match?(/\A[\d.]+\z/) || host.match?(/\.\d+\z/)
    end

    def non_public_ip?(ip)
      ranges = ip.ipv4? ? NON_PUBLIC_IPV4_RANGES : NON_PUBLIC_IPV6_RANGES

      ranges.any? { |range| range.include?(ip) }
    end

    def public_hostname?(host)
      return false unless host.match?(PUBLIC_HOSTNAME)
      return false if INTERNAL_HOSTNAMES.include?(host)

      INTERNAL_HOSTNAME_SUFFIXES.none? { |suffix| host.end_with?(suffix) }
    end
  end
end
