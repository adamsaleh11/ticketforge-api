require "rails_helper"

RSpec.describe LLM::GroqClient do
  let(:model) { "llama-3.3-70b-versatile" }
  let(:url) { "https://api.groq.com/openai/v1/chat/completions" }
  let(:api_key) { "test-groq-key" }

  subject(:client) { described_class.new(model: model) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GROQ_API_KEY").and_return(api_key)
  end

  def stub_groq(status: 200, body:)
    stub_request(:post, url).to_return(
      status: status,
      body: body.is_a?(String) ? body : body.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def chat_response(content)
    { "choices" => [{ "message" => { "role" => "assistant", "content" => content } }] }
  end

  describe "request timeout" do
    it "defaults to the shared 60s timeout" do
      stub_groq(body: chat_response("ok"))
      allow(HTTParty).to receive(:post).and_call_original

      client.chat(system: "s", user: "u")

      expect(HTTParty).to have_received(:post).with(anything, hash_including(timeout: 60))
    end

    it "applies a custom timeout supplied via the factory" do
      stub_groq(body: chat_response("ok"))
      allow(HTTParty).to receive(:post).and_call_original

      LLM::Client.for(provider: :groq, model: model, timeout: 110)
        .chat(system: "s", user: "u")

      expect(HTTParty).to have_received(:post).with(anything, hash_including(timeout: 110))
    end
  end

  describe "#chat (json mode)" do
    it "returns the assistant content parsed as a Hash" do
      stub_groq(body: chat_response('{"phases":["a","b"]}'))

      result = client.chat(system: "sys", user: "usr", json_mode: true)

      expect(result).to eq("phases" => %w[a b])
    end

    it "asks Groq for a JSON object via response_format" do
      stub_groq(body: chat_response("{}"))

      client.chat(system: "sys", user: "usr", json_mode: true)

      expect(WebMock).to have_requested(:post, url)
        .with(body: hash_including("response_format" => { "type" => "json_object" }))
    end
  end

  describe "#chat (text mode)" do
    it "returns the assistant message content as a string" do
      stub_groq(body: chat_response("Hello from Groq"))

      result = client.chat(system: "You are helpful.", user: "Hi")

      expect(result).to eq("Hello from Groq")
    end

    it "POSTs an OpenAI-shaped payload with a bearer token" do
      stub_groq(body: chat_response("ok"))

      client.chat(system: "sys prompt", user: "user prompt")

      expect(WebMock).to have_requested(:post, url)
        .with(
          headers: { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" },
          body: hash_including(
            "model" => model,
            "messages" => [
              { "role" => "system", "content" => "sys prompt" },
              { "role" => "user", "content" => "user prompt" }
            ]
          )
        )
    end
  end

  describe "#chat (invalid responses)" do
    it "raises InvalidResponseError when the body is not valid JSON" do
      stub_groq(body: "not json at all")

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::InvalidResponseError)
    end

    it "raises InvalidResponseError when the content field is missing" do
      stub_groq(body: { "choices" => [{ "message" => {} }] })

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::InvalidResponseError)
    end

    it "raises InvalidResponseError when json_mode content is not valid JSON" do
      stub_groq(body: chat_response("I am not JSON"))

      expect { client.chat(system: "s", user: "u", json_mode: true) }
        .to raise_error(LLM::InvalidResponseError)
    end
  end

  describe "#chat (HTTP errors)" do
    [401, 500].each do |status|
      it "raises InvalidResponseError on #{status} without retrying" do
        stub_request(:post, url).to_return(status: status, body: "nope")

        expect { client.chat(system: "s", user: "u") }
          .to raise_error(LLM::InvalidResponseError)
        expect(WebMock).to have_requested(:post, url).once
      end
    end
  end

  describe "#chat (connection failures)" do
    it "raises ConnectionError and retries exactly once (two attempts)" do
      stub_request(:post, url).to_timeout

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::ConnectionError)
      expect(WebMock).to have_requested(:post, url).twice
    end

    it "raises ConnectionError on a refused connection" do
      stub_request(:post, url).to_raise(Errno::ECONNREFUSED)

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::ConnectionError)
    end
  end

  describe "#chat (missing API key)" do
    it "raises ConnectionError before making any request" do
      allow(ENV).to receive(:[]).with("GROQ_API_KEY").and_return(nil)

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::ConnectionError)
      expect(WebMock).not_to have_requested(:post, url)
    end
  end
end
