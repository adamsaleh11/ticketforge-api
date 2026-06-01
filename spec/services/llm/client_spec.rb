require "rails_helper"

RSpec.describe LLM::Client do
  describe ".for" do
    it "returns a GroqClient for the :groq provider" do
      client = described_class.for(provider: :groq, model: "llama-3.3-70b")
      expect(client).to be_a(LLM::GroqClient)
    end

    it "accepts the provider as a string" do
      client = described_class.for(provider: "groq", model: "llama-3.3-70b")
      expect(client).to be_a(LLM::GroqClient)
    end

    it "returns an OllamaClient for the :ollama provider" do
      client = described_class.for(provider: :ollama, model: "llama3", endpoint: nil)
      expect(client).to be_a(LLM::OllamaClient)
    end

    it "raises ArgumentError for an unknown provider" do
      expect { described_class.for(provider: :anthropic, model: "claude") }
        .to raise_error(ArgumentError)
    end

    it "keeps the unknown-provider error outside the LLM::Error tree" do
      # A bad provider is a caller bug, not a backend failure, so callers
      # rescuing LLM::Error must not accidentally swallow it.
      expect(ArgumentError.ancestors).not_to include(LLM::Error)
    end
  end
end
