module LLM
  # Talks to a self-hosted Ollama server's native /api/chat endpoint.
  class OllamaClient < Client
    DEFAULT_ENDPOINT = "http://localhost:11434".freeze

    def initialize(model:, endpoint: nil)
      @model = model
      @endpoint = endpoint.presence || DEFAULT_ENDPOINT
    end

    private

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
