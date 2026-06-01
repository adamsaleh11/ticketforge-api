# Plan: Unified LLM Service

> Source PRD: docs/prd-llm-service.md

## Architectural decisions

Durable decisions that apply across all phases:

- **Namespace / structure**: `LLM` module under `app/services/llm/`. `LLM::Client` is *both* the factory and the abstract base class (mirrors the `SupabaseAuth::Verifier` "hide the machinery behind one class" convention). Subclasses `LLM::GroqClient` and `LLM::OllamaClient`.
- **Error hierarchy**: `LLM::Error < StandardError`; `LLM::ConnectionError < LLM::Error`; `LLM::InvalidResponseError < LLM::Error`. Defined alongside the base client. Unknown provider → `ArgumentError` (deliberately outside the `LLM::Error` tree).
- **Factory**: `LLM::Client.for(provider:, model:, endpoint: nil)`. `provider` accepts String or Symbol, normalized; dispatches `:groq`/`:ollama`. `model` required for both. `endpoint` ignored by Groq; Ollama defaults to `http://localhost:11434`.
- **Public method**: `chat(system:, user:, json_mode: false)`. `system:`/`user:` required, mapped to system+user role messages. Returns a **String** in text mode (raw content) and a **parsed Hash** (string keys) in JSON mode.
- **Transport**: HTTParty for both providers. JSON body sent as a serialized string with explicit `Content-Type: application/json`. `timeout: 60` per request.
- **Retry**: exactly one retry, connection-class failures only (refused/timeout/reset/DNS/socket). Second connection failure → `ConnectionError`. No backoff. Non-2xx is never retried.
- **Error mapping**: connection-class (post-retry) → `ConnectionError`; any non-2xx → `InvalidResponseError` (status + truncated body in message); 2xx unparseable body → `InvalidResponseError`; 2xx missing content field → `InvalidResponseError`; `json_mode` content not valid JSON → `InvalidResponseError`; Groq blank `GROQ_API_KEY` → `ConnectionError` before any request. Raw HTTP/socket exceptions never leak.
- **JSON mode wire directive**: Groq sets `response_format: { type: "json_object" }`; Ollama sets top-level `format: "json"`. The service *also* parses content itself — the parse is the `InvalidResponseError` gate.
- **Out of scope (all phases)**: streaming, tuning params (temperature/top_p/max_tokens), logging/metrics, async, backoff/multi-retry, model validation, caching, 429/`Retry-After` handling.
- **Testing**: WebMock (already configured in `spec/support/webmock.rb`; real net-connect disabled, localhost allowed but stubs win). Specs under `spec/services/llm/`. `GROQ_API_KEY` controlled by stubbing `ENV`. No external services required.

---

## Phase 1: Foundation + Groq end-to-end

**User stories**: 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15

### What to build

The complete shared machinery plus the first working provider. Define the `LLM` error hierarchy and the `LLM::Client` factory + abstract base owning the 60s timeout, single-retry-on-connection-error loop, exception wrapping, and JSON parse/validation. Implement `LLM::GroqClient` (OpenAI-compatible payload to the Groq chat completions endpoint, `Authorization: Bearer` from `GROQ_API_KEY`, content from `choices[0].message.content`). Wire `:groq` into the factory; unknown provider raises `ArgumentError`. End-to-end demoable: `LLM::Client.for(provider: :groq, model: "...").chat(system:, user:, json_mode:)`.

### Acceptance criteria

- [ ] `LLM::Client.for(provider: :groq, model:)` (String or Symbol) returns a `GroqClient`; an unknown provider raises `ArgumentError` (not an `LLM::Error`).
- [ ] Text-mode `chat` returns the assistant content as a String; request goes to the Groq completions URL with a `Bearer` auth header and an OpenAI-shaped body (`model`, system+user `messages`).
- [ ] JSON-mode `chat` returns a parsed Hash and includes `response_format: { type: "json_object" }` in the request body.
- [ ] 200 with malformed JSON, 200 with missing `choices[0].message.content`, and JSON-mode content that isn't valid JSON each raise `InvalidResponseError`.
- [ ] 401 and 500 raise `InvalidResponseError` and the request is made exactly **once** (no retry).
- [ ] A connection failure (timeout / `ECONNREFUSED`) raises `ConnectionError` and the request is attempted exactly **twice** (one retry).
- [ ] A blank/missing `GROQ_API_KEY` raises `ConnectionError` with **no** HTTP request made.
- [ ] All Groq behavior covered by WebMock-stubbed specs under `spec/services/llm/`; no real network access.

---

## Phase 2: Ollama end-to-end

**User stories**: 8, 9 (and 2, 3, 4, 5, 6, 7 re-proven for Ollama)

### What to build

Add `LLM::OllamaClient` against the Phase 1 base with **no changes to base logic** — proving the template-method seam generalizes to a differently-shaped provider. Native Ollama payload to `<endpoint>/api/chat` with `stream: false`, `format: "json"` in JSON mode, no auth header, content from `message.content`, default endpoint `http://localhost:11434`. Wire `:ollama` into the factory.

### Acceptance criteria

- [ ] `LLM::Client.for(provider: :ollama, model:, endpoint:)` (String or Symbol) returns an `OllamaClient`.
- [ ] Text-mode `chat` returns the content String; request goes to `<endpoint>/api/chat` with `stream: false` and system+user `messages` in the body.
- [ ] JSON-mode `chat` returns a parsed Hash and includes top-level `format: "json"` in the request body.
- [ ] 200 with malformed JSON / missing `message.content` raises `InvalidResponseError`.
- [ ] A non-2xx response raises `InvalidResponseError`, made exactly **once**; a connection failure raises `ConnectionError`, attempted exactly **twice**.
- [ ] A custom `endpoint:` is honored in the request URL; `endpoint: nil` defaults to `http://localhost:11434`.
- [ ] No new logic added to the base `LLM::Client`; Ollama-specific behavior lives entirely in `OllamaClient`.
- [ ] All Ollama behavior covered by WebMock-stubbed specs under `spec/services/llm/`; no real network access.
