module LLM
  # Talks to Groq's OpenAI-compatible chat completions API.
  class GroqClient < Client
    URL = "https://api.groq.com/openai/v1/chat/completions".freeze

    def initialize(model:, endpoint: nil)
      @model = model
    end

    private

    def request_url
      URL
    end

    def request_headers
      {
        "Authorization" => "Bearer #{api_key}",
        "Content-Type" => "application/json"
      }
    end

    def request_body(system:, user:, json_mode:)
      body = { model: @model, messages: messages(system: system, user: user) }
      body[:response_format] = { type: "json_object" } if json_mode
      body
    end

    def extract_content(parsed)
      parsed.dig("choices", 0, "message", "content")
    end

    def ensure_ready!
      return if api_key.present?

      raise ConnectionError, "GROQ_API_KEY is not set"
    end

    def api_key
      ENV["GROQ_API_KEY"]
    end
  end
end
