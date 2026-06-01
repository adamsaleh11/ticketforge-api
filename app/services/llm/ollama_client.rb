module LLM
  # Talks to a self-hosted Ollama server's native /api/chat endpoint.
  class OllamaClient < Client
    DEFAULT_ENDPOINT = "http://localhost:11434".freeze

    # Read timeout for the lightweight connectivity check, deliberately far
    # shorter than the chat path's TIMEOUT so a wrong/hung endpoint fails fast.
    TAGS_TIMEOUT = 5 # seconds

    # model is optional: it is unused by the connectivity check (#list_models)
    # and only required by the chat path.
    def initialize(model: nil, endpoint: nil, timeout: nil)
      @model = model
      @endpoint = endpoint.presence || DEFAULT_ENDPOINT
      @timeout = timeout
    end

    # Lists the models installed on the Ollama server via its native /api/tags
    # endpoint. Returns an array of model name strings. Surfaces the shared
    # LLM::Error taxonomy (ConnectionError / InvalidResponseError) on failure so
    # callers handle Ollama connectivity the same way as the chat path.
    def list_models
      response = get_tags
      parsed = parse_tags_body(response)
      Array(parsed["models"]).map { |m| m["name"] }.compact
    end

    private

    def get_tags
      response = HTTParty.get("#{@endpoint}/api/tags", timeout: TAGS_TIMEOUT)
      unless response.success?
        raise InvalidResponseError,
              "#{self.class.name} returned HTTP #{response.code} from /api/tags"
      end

      response
    rescue *Client::CONNECTION_ERRORS => e
      raise ConnectionError, "#{self.class.name} could not reach the backend: #{e.message}"
    end

    def parse_tags_body(response)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise InvalidResponseError, "#{self.class.name} returned an unparseable /api/tags body: #{e.message}"
    end

    def request_url
      "#{@endpoint}/api/chat"
    end

    def request_headers
      { "Content-Type" => "application/json" }
    end

    def request_body(system:, user:, json_mode:)
      body = {
        model: @model,
        messages: messages(system: system, user: user),
        stream: false # required: otherwise Ollama streams NDJSON chunks
      }
      body[:format] = "json" if json_mode
      body
    end

    def extract_content(parsed)
      parsed.dig("message", "content")
    end
  end
end
