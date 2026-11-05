module Ai
  # Provider adapter for Gemini. It returns an Ai::Diagnosis::Result only when the
  # model output passes every validation; any transport error, non-2xx answer or
  # malformed payload returns nil so the caller records the deterministic fallback.
  # Provider details are never logged or returned, because the prompt and the
  # answer can both contain customer evidence.
  class GeminiFailureDiagnoser
    DEFAULT_MODEL = 'gemini-2.5-flash'
    DEFAULT_TIMEOUT_MS = 8000
    MIN_TIMEOUT_MS = 1000
    MAX_TIMEOUT_MS = 30_000
    API_HOST = 'https://generativelanguage.googleapis.com'
    PROMPT_MAX_BYTES = 12_000

    INSTRUCTIONS = <<~PROMPT.squish
      You classify why an outbound webhook delivery to a customer receiver failed.
      Answer with JSON only: {"label": <one of: #{Diagnosis::LABELS.join(', ')}>,
      "suggested_action": <one concise, actionable sentence for the integration team>}.
      Use "unknown" when the evidence does not identify a clearer cause.
    PROMPT

    def initialize(api_key: ENV.fetch('GEMINI_API_KEY', nil),
                   model: ENV.fetch('AI_DIAGNOSIS_MODEL', DEFAULT_MODEL),
                   timeout_ms: ENV.fetch('AI_DIAGNOSIS_TIMEOUT_MS', DEFAULT_TIMEOUT_MS),
                   transport: Ai::HttpTransport.new)
      @api_key = api_key
      @model = model.presence || DEFAULT_MODEL
      @timeout_seconds = normalize_timeout_ms(timeout_ms)
      @transport = transport
    end

    def call(attempts)
      return nil if api_key.blank?

      parse(request(attempts))
    rescue StandardError
      nil
    end

    private

    attr_reader :api_key, :model, :timeout_seconds, :transport

    def request(attempts)
      transport.post_json(
        url: endpoint_url,
        headers: { 'x-goog-api-key' => api_key },
        body: Oj.dump(request_body(attempts), mode: :compat),
        open_timeout: timeout_seconds,
        read_timeout: timeout_seconds
      )
    end

    def endpoint_url
      "#{API_HOST}/v1beta/models/#{model}:generateContent"
    end

    def request_body(attempts)
      {
        contents: [{ role: 'user', parts: [{ text: prompt(attempts) }] }],
        generationConfig: {
          temperature: 0,
          responseMimeType: 'application/json',
          responseSchema: response_schema
        }
      }
    end

    def response_schema
      {
        type: 'OBJECT',
        properties: {
          label: { type: 'STRING', enum: Diagnosis::LABELS },
          suggested_action: { type: 'STRING' }
        },
        required: %w[label suggested_action]
      }
    end

    def prompt(attempts)
      contexts = attempts.map { |attempt| AttemptContext.for(attempt) }
      text = [INSTRUCTIONS, Oj.dump(contexts, mode: :compat)].join("\n\n")

      Webhooks::ResponseEvidence.normalize_external_text(text.byteslice(0, PROMPT_MAX_BYTES))
    end

    def parse(result)
      return nil unless result.status.between?(200, 299)

      build_result(**extract_answer(result.body))
    rescue JSON::ParserError, EncodingError, ArgumentError, TypeError
      nil
    end

    def extract_answer(body)
      answer = JSON.parse(JSON.parse(body.to_s).dig('candidates', 0, 'content', 'parts', 0, 'text').to_s)

      raise JSON::ParserError, 'answer is not a JSON object' unless answer.is_a?(Hash)

      { label: answer['label'], suggested_action: answer['suggested_action'] }
    end

    def build_result(label:, suggested_action:)
      normalized_label = label.to_s
      action = suggested_action.to_s.strip
      return nil unless Diagnosis::LABELS.include?(normalized_label)
      return nil if action.empty? || action.length > Diagnosis::ACTION_MAX_LENGTH

      Diagnosis::Result.new(
        label: normalized_label,
        suggested_action: action,
        source: Diagnosis::SOURCE_AI,
        model: model
      )
    end

    def normalize_timeout_ms(timeout_ms)
      timeout_ms.to_i.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS) / 1000.0
    end
  end
end
