require "rails_helper"

RSpec.describe LLM::OllamaClient do
  let(:model) { "llama3" }
  let(:default_url) { "http://localhost:11434/api/chat" }

  subject(:client) { described_class.new(model: model) }

  def stub_ollama(url: default_url, status: 200, body:)
    stub_request(:post, url).to_return(
      status: status,
      body: body.is_a?(String) ? body : body.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def chat_response(content)
    { "message" => { "role" => "assistant", "content" => content } }
  end

  describe "#chat (text mode)" do
    it "returns the assistant message content as a string" do
      stub_ollama(body: chat_response("Hello from Ollama"))

      result = client.chat(system: "You are helpful.", user: "Hi")

      expect(result).to eq("Hello from Ollama")
    end

    it "POSTs an Ollama-native payload with stream disabled" do
      stub_ollama(body: chat_response("ok"))

      client.chat(system: "sys prompt", user: "user prompt")

      expect(WebMock).to have_requested(:post, default_url)
        .with(body: hash_including(
          "model" => model,
          "stream" => false,
          "messages" => [
            { "role" => "system", "content" => "sys prompt" },
            { "role" => "user", "content" => "user prompt" }
          ]
        ))
    end
  end

  describe "#chat (json mode)" do
    it "returns the assistant content parsed as a Hash" do
      stub_ollama(body: chat_response('{"phases":["a"]}'))

      result = client.chat(system: "s", user: "u", json_mode: true)

      expect(result).to eq("phases" => %w[a])
    end

    it "asks Ollama for JSON via the top-level format field" do
      stub_ollama(body: chat_response("{}"))

      client.chat(system: "s", user: "u", json_mode: true)

      expect(WebMock).to have_requested(:post, default_url)
        .with(body: hash_including("format" => "json"))
    end
  end

  describe "endpoint handling" do
    it "defaults to http://localhost:11434 when endpoint is nil" do
      stub_ollama(body: chat_response("ok"))

      described_class.new(model: model, endpoint: nil).chat(system: "s", user: "u")

      expect(WebMock).to have_requested(:post, default_url)
    end

    it "honors a custom endpoint" do
      custom = "http://ollama.internal:9999"
      stub_ollama(url: "#{custom}/api/chat", body: chat_response("ok"))

      described_class.new(model: model, endpoint: custom).chat(system: "s", user: "u")

      expect(WebMock).to have_requested(:post, "#{custom}/api/chat")
    end
  end

  describe "#chat (failures)" do
    it "raises InvalidResponseError on a malformed JSON body" do
      stub_ollama(body: "not json")

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::InvalidResponseError)
    end

    it "raises InvalidResponseError when message content is missing" do
      stub_ollama(body: { "message" => {} })

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::InvalidResponseError)
    end

    it "raises InvalidResponseError on a non-2xx response without retrying" do
      stub_request(:post, default_url).to_return(status: 500, body: "boom")

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::InvalidResponseError)
      expect(WebMock).to have_requested(:post, default_url).once
    end

    it "raises ConnectionError and retries once on a connection failure" do
      stub_request(:post, default_url).to_timeout

      expect { client.chat(system: "s", user: "u") }
        .to raise_error(LLM::ConnectionError)
      expect(WebMock).to have_requested(:post, default_url).twice
    end
  end

  describe "#list_models" do
    let(:tags_url) { "http://localhost:11434/api/tags" }

    subject(:client) { described_class.new(endpoint: nil) }

    it "returns the installed model names from /api/tags" do
      stub_request(:get, tags_url).to_return(
        status: 200,
        body: { "models" => [{ "name" => "llama3:latest" }, { "name" => "qwen2:7b" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect(client.list_models).to eq(["llama3:latest", "qwen2:7b"])
    end

    it "queries a custom endpoint's /api/tags" do
      custom = "http://ollama.internal:9999"
      stub_request(:get, "#{custom}/api/tags").to_return(
        status: 200, body: { "models" => [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      described_class.new(endpoint: custom).list_models

      expect(WebMock).to have_requested(:get, "#{custom}/api/tags")
    end

    it "raises InvalidResponseError on a non-2xx response" do
      stub_request(:get, tags_url).to_return(status: 500, body: "boom")

      expect { client.list_models }.to raise_error(LLM::InvalidResponseError)
    end

    it "raises InvalidResponseError on an unparseable body" do
      stub_request(:get, tags_url).to_return(status: 200, body: "not json")

      expect { client.list_models }.to raise_error(LLM::InvalidResponseError)
    end

    it "raises ConnectionError on a transport failure" do
      stub_request(:get, tags_url).to_timeout

      expect { client.list_models }.to raise_error(LLM::ConnectionError)
    end
  end
end
