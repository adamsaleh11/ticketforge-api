module LLM
  # Base class for all LLM client failures. Callers can rescue LLM::Error to
  # catch every failure this service raises.
  class Error < StandardError; end

  # The backend could not be reached: DNS failure, refused connection, reset,
  # timeout (after the single retry), or — for Groq — a missing API key caught
  # before any request is made.
  class ConnectionError < Error; end

  # The backend answered but the answer was unusable: any non-2xx status, an
  # unparseable body, a missing content field, or (in JSON mode) content that
  # is not valid JSON.
  class InvalidResponseError < Error; end

  # Provider-agnostic LLM client. Acts as both the factory (`.for`) and the
  # abstract base that owns the shared transport, retry, error-wrapping, and
  # JSON parsing. Subclasses supply the provider-specific request shape and
  # response extraction.
  class Client
    PROVIDERS = {
      groq: "LLM::GroqClient",
      ollama: "LLM::OllamaClient"
    }.freeze

    TIMEOUT = 60 # seconds, applied to both open and read

    # Transport/socket failures that may be transient and are worth one retry.
    # A non-2xx HTTP status is NOT in this list — that is a definitive answer.
    CONNECTION_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
      Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError, Timeout::Error
    ].freeze

    # Returns a provider-specific client. `provider` may be a String or Symbol.
    # An unknown provider raises ArgumentError (a caller bug), deliberately
    # outside the LLM::Error tree.
    def self.for(provider:, model:, endpoint: nil)
      klass_name = PROVIDERS[provider.to_sym]
      raise ArgumentError, "unknown LLM provider: #{provider.inspect}" unless klass_name

      klass_name.constantize.new(model: model, endpoint: endpoint)
    end

    # Sends a system + user prompt and returns the model's reply. In text mode
    # (json_mode: false) returns the content String; in JSON mode returns the
    # parsed Hash (and raises InvalidResponseError if the content isn't valid
    # JSON).
    def chat(system:, user:, json_mode: false)
      ensure_ready!
      response = post(request_body(system: system, user: user, json_mode: json_mode))
      content = extract_content(parse_body(response))
      if content.nil?
        raise InvalidResponseError, "#{self.class.name} response was missing message content"
      end

      json_mode ? parse_json_content(content) : content
    end

    private

    # Single retry on connection-class failures only; never on a non-2xx
    # status. The second consecutive connection failure becomes a
    # ConnectionError.
    def post(body)
      attempts = 0
      begin
        attempts += 1
        send_request(body)
      rescue *CONNECTION_ERRORS => e
        retry if attempts < 2
        raise ConnectionError, "#{self.class.name} could not reach the backend: #{e.message}"
      end
    end

    def send_request(body)
      response = HTTParty.post(
        request_url,
        body: body.to_json,
        headers: request_headers,
        timeout: TIMEOUT
      )

      unless response.success?
        raise InvalidResponseError,
              "#{self.class.name} returned HTTP #{response.code}: #{response.body.to_s[0, 500]}"
      end

      response
    end

    # Subclass hook for fail-fast preconditions (e.g. a required API key)
    # checked before any network call. Default: no-op.
    def ensure_ready!; end

    def parse_body(response)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise InvalidResponseError, "#{self.class.name} returned an unparseable body: #{e.message}"
    end

    def parse_json_content(content)
      JSON.parse(content)
    rescue JSON::ParserError => e
      raise InvalidResponseError, "#{self.class.name} returned non-JSON content in JSON mode: #{e.message}"
    end

    # Shared OpenAI/Ollama-style message array.
    def messages(system:, user:)
      [
        { role: "system", content: system },
        { role: "user", content: user }
      ]
    end

    # --- Template methods implemented by subclasses ---

    def request_url
      raise NotImplementedError
    end

    def request_headers
      raise NotImplementedError
    end

    def request_body(system:, user:, json_mode:)
      raise NotImplementedError
    end

    def extract_content(parsed)
      raise NotImplementedError
    end
  end
end
