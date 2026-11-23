module ActiveStorageConfiguration
  SERVICE_ENV_KEY = 'ACTIVE_STORAGE_SERVICE'
  SERVICES = {
    'amazon' => :amazon,
    'local' => :local
  }.freeze
  AMAZON_ENV_KEYS = %w[AWS_REGION AWS_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

  class InvalidServiceError < StandardError; end
  class MissingAmazonConfigurationError < StandardError; end

  class << self
    def configure!(config:, env:, logger:)
      service = service_name(env:)
      ensure_amazon_configured!(env:) if service == :amazon
      config.service = service
      warn_ephemeral_local_storage!(logger) if service == :local
    end

    def service_name(env:)
      configured_service = env.fetch(SERVICE_ENV_KEY, 'amazon').to_s.strip.downcase

      SERVICES.fetch(configured_service) do
        raise InvalidServiceError,
              "#{SERVICE_ENV_KEY} must be one of: #{SERVICES.keys.join(', ')}"
      end
    end

    private

    def ensure_amazon_configured!(env:)
      missing_keys = AMAZON_ENV_KEYS.select { |key| env.fetch(key, nil).to_s.strip.empty? }
      return if missing_keys.empty?

      raise MissingAmazonConfigurationError,
            "Amazon Active Storage requires: #{missing_keys.join(', ')}"
    end

    def warn_ephemeral_local_storage!(logger)
      logger.warn('ACTIVE_STORAGE_SERVICE=local uses ephemeral Render filesystem; uploaded files can be lost on restart or spin-down')
    end
  end
end
