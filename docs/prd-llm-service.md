# PRD: Unified LLM Service

## Problem Statement

TicketForge's core product loop is "describe a project → generate phased engineering tickets." That generation step requires calling a large language model. The product supports two LLM backends with very different wire protocols: **Groq** (a hosted, OpenAI-compatible chat completions API requiring an API key) and **Ollama** (a self-hosted, OpenAI-incompatible local server, default `http://localhost:11434`, no auth). The `Project` resource already persists which `llm_provider` (`groq`/`ollama`) and `llm_model` a user picked, but the API has no way to actually *talk* to either backend.

Without a unified client, every caller that wants to generate text (starting with the ticket-generation pipeline in Phase 5) would have to know each provider's URL, payload shape, auth scheme, response envelope, timeout handling, and retry semantics — and would re-implement that, divergently, at every call site. This affects every feature downstream of project creation: nothing in the generation path can be built until there is one reliable, provider-agnostic way to send a system+user prompt and get back text (or structured JSON). It matters now because ticket generation is the next major feature and is fully blocked on this contract.

## Solution

Introduce a single, provider-agnostic LLM service. A caller asks a factory for a client by provider, model, and (for Ollama) endpoint, then calls one method — `chat(system:, user:, json_mode:)` — and gets back either a plain string or a parsed JSON hash. The caller never sees HTTP, never sees the difference between Groq's and Ollama's payloads or response envelopes, and never handles raw network exceptions.

The service hides all provider-specific complexity behind a stable interface:

- **Provider selection** is a factory call. The caller passes the provider/model it already stored on the `Project`; the factory returns the right client.
- **One calling convention** for both providers: a system prompt, a user prompt, and an optional `json_mode` flag. In text mode the result is the assistant's message content as a string. In JSON mode the service instructs the provider to emit JSON *and* parses it, returning a Hash — so the caller never parses model output itself.
- **Uniform failure model.** Every failure collapses into one of two errors the caller can reason about: a `ConnectionError` (the backend was unreachable — DNS, refused connection, timeout, or, for Groq, a missing API key caught before any request) or an `InvalidResponseError` (the backend answered but the answer was unusable — any non-2xx status, an unparseable body, a missing content field, or, in JSON mode, content that isn't valid JSON). Raw HTTP/transport exceptions never leak.
- **Resilience built in.** A 60-second timeout per request and exactly one automatic retry, but *only* for connection-class failures — never for a 4xx/5xx, which is treated as a definitive answer.

This gives the future ticket-generation service a deep, dependable building block: hand it a prompt, get back text or JSON, and handle exactly two well-defined error types.

## User Stories

1. As the ticket-generation service, I want to obtain an LLM client by passing the provider and model already stored on a project, so that I don't branch on provider type at the call site.
2. As the ticket-generation service, I want to send a system prompt and a user prompt and receive the model's text response as a string, so that I can use generated content directly.
3. As the ticket-generation service, I want to request JSON mode and receive an already-parsed hash, so that I never have to parse or repair raw model output myself.
4. As the ticket-generation service, I want a single timeout policy (60s) applied to every provider, so that a slow or hung backend can't block a request indefinitely.
5. As the ticket-generation service, I want one automatic retry on connection failures, so that a transient network blip doesn't surface as a user-visible error.
6. As the ticket-generation service, I want non-2xx HTTP responses to fail immediately without retry, so that a deterministic error (bad request, auth failure, server error) isn't pointlessly repeated and latency isn't doubled.
7. As the ticket-generation service, I want every failure to surface as either a `ConnectionError` or an `InvalidResponseError`, so that I can rescue exactly two types and never leak a raw HTTP or socket exception to the user.
8. As an operator running a self-hosted Ollama, I want to point the client at a custom endpoint, so that I can use a non-default host or port.
9. As an operator who hasn't configured a custom Ollama endpoint, I want the client to default to `http://localhost:11434`, so that the common local case needs no configuration.
10. As a developer using the Groq client, I want a missing `GROQ_API_KEY` to fail fast as a `ConnectionError` before any HTTP call, so that I get a clear failure instead of an unauthenticated request to Groq.
11. As a developer integrating either provider, I want JSON mode to actually instruct the provider to emit JSON (`response_format` for Groq, `format` for Ollama), so that the model cooperates rather than relying on the prompt alone.
12. As a developer, I want a response that returns 2xx but contains malformed JSON, or is missing the expected content field, to raise `InvalidResponseError`, so that a "successful" but unusable response doesn't silently return `nil`.
13. As a developer, I want JSON mode with content that isn't valid JSON to raise `InvalidResponseError`, so that I can trust that a Hash return always means well-formed JSON.
14. As a developer, I want to call the factory with an unknown provider and get a plain `ArgumentError` (not an `LLM::Error`), so that a programming mistake is distinct from a runtime backend failure.
15. As a maintainer, I want both providers to share one transport, retry, error-wrapping, and JSON-parsing implementation, so that the tricky resilience logic exists in exactly one place and can't drift between providers.

## Implementation Decisions

### Modules

- **`LLM` module + error hierarchy** — defines `LLM::Error < StandardError`, with `LLM::ConnectionError < LLM::Error` and `LLM::InvalidResponseError < LLM::Error`. Defined alongside the base client so requiring any client makes the error types available.
- **`LLM::Client` (factory + abstract base)** — a deep module that is *both* the factory and the shared base class:
  - **Factory:** `LLM::Client.for(provider:, model:, endpoint: nil)` accepts `provider` as a String or Symbol, normalizes it, and returns a `GroqClient` or `OllamaClient`. An unrecognized provider raises `ArgumentError` (deliberately outside the `LLM::Error` tree — it's a caller bug, not a backend failure).
  - **Base behavior:** owns the public `chat(system:, user:, json_mode: false)` method, the 60-second timeout, the single-retry-on-connection-error loop, the exception wrapping (`ConnectionError`/`InvalidResponseError`), and the JSON parsing/validation step.
  - **Template seams** the two subclasses implement: the request URL, the request body for a given system/user/json_mode, the request headers, and how to extract the assistant content from a parsed response envelope.
- **`LLM::GroqClient`** — targets `POST https://api.groq.com/openai/v1/chat/completions`. Sends an OpenAI-compatible payload (`model`, `messages` as system+user roles, and `response_format: { type: "json_object" }` when JSON mode is on). Sets `Authorization: Bearer <GROQ_API_KEY>` (read from env) and `Content-Type: application/json`. A blank `GROQ_API_KEY` raises `ConnectionError` before any request is made. Extracts content from `choices[0].message.content`.
- **`LLM::OllamaClient`** — targets `POST <endpoint>/api/chat`, defaulting `endpoint` to `http://localhost:11434`. Sends an Ollama-native payload (`model`, `messages`, `stream: false`, and `format: "json"` when JSON mode is on). `stream: false` is mandatory so the response is a single JSON object rather than streamed NDJSON. No auth header. Extracts content from `message.content`.

### Interfaces / behavior

- **Calling convention:** `chat(system:, user:, json_mode: false)`. `system:` and `user:` are required keywords mapped to two messages (`system`, `user` roles). Returns a **String** when `json_mode` is false (raw assistant content, untouched) and a **parsed Hash** (string keys) when `json_mode` is true.
- **JSON mode contract:** the service both sets the provider's JSON directive *and* parses the returned content itself. The parse is the gate that distinguishes a usable JSON response from an `InvalidResponseError`. The service never trusts the provider to have honored the directive.
- **HTTP client:** HTTParty for both providers (the Gemfile already bundles it; using one library for both keeps transport/timeout/retry handling uniform). JSON bodies are sent as a serialized JSON string with an explicit content-type header. `timeout: 60` is applied per request (covers both open and read).
- **Retry policy:** exactly one retry, connection-class only. Connection-class = transport/socket failures (connection refused, timeout, reset, DNS/socket errors). On the second connection failure, raise `ConnectionError`. No backoff/sleep. A non-2xx HTTP status is *not* a connection error and is never retried — it maps straight to `InvalidResponseError`.
- **No extra tuning params** (temperature, top_p, max_tokens, etc.) are sent in this iteration; payloads stay minimal.

### Error mapping (the contract callers rely on)

| Situation | Raised |
|---|---|
| Connection refused, timeout, reset, DNS/socket error (after the one retry) | `LLM::ConnectionError` |
| Any non-2xx HTTP status (4xx or 5xx) | `LLM::InvalidResponseError` (message includes status + truncated body) |
| 2xx but body is not parseable JSON | `LLM::InvalidResponseError` |
| 2xx, parseable, but expected content field absent | `LLM::InvalidResponseError` |
| `json_mode: true` and the content string isn't valid JSON | `LLM::InvalidResponseError` |
| Groq: blank/missing `GROQ_API_KEY` | `LLM::ConnectionError`, raised before any HTTP request |
| Unknown provider passed to the factory | `ArgumentError` (outside the `LLM::Error` tree) |

Underlying exceptions are rescued and re-raised wrapped; the original message is preserved in the wrapped error's message.

## Testing Decisions

Good tests here assert the external behavior and the failure contract — what string/hash comes back, what request goes out (URL, headers, body shape), which of the two error types is raised, and whether a retry happened — not the internal template-method wiring. WebMock is already configured (`spec/support/webmock.rb` disables real net connect; localhost is allowed but explicit stubs still take priority, so `localhost:11434` is stubbable). Stub both providers; never hit the network.

Coverage to call out, under `spec/services/llm/`:

- **Factory (`LLM::Client.for`)** — dispatches `:groq`/`"groq"` to `GroqClient` and `:ollama`/`"ollama"` to `OllamaClient`; an unknown provider raises `ArgumentError` (and *not* an `LLM::Error`).
- **`GroqClient`**:
  - Text-mode happy path → returns the content string; assert request URL, the `Authorization: Bearer` header, and the OpenAI-shaped body (`model`, system+user `messages`) via a `with(body: ...)` matcher.
  - JSON-mode happy path → returns a parsed Hash; assert `response_format: { type: "json_object" }` is present in the request body.
  - 200 with malformed JSON body → `InvalidResponseError`.
  - 200 with `choices[0].message.content` missing → `InvalidResponseError`.
  - JSON mode where content isn't valid JSON → `InvalidResponseError`.
  - 401 and 500 → `InvalidResponseError`, and assert the request was made exactly **once** (no retry).
  - Connection failure (`to_timeout` / raise `Errno::ECONNREFUSED`) → `ConnectionError`, and assert the request was attempted exactly **twice** (one retry).
  - Blank/missing `GROQ_API_KEY` → `ConnectionError`, and assert **no** HTTP request was made.
- **`OllamaClient`**:
  - Text-mode happy path → returns the content string; assert URL is `<endpoint>/api/chat`, body has `stream: false`, system+user `messages`.
  - JSON-mode happy path → returns a parsed Hash; assert top-level `format: "json"` in the request body.
  - 200 with malformed JSON / missing `message.content` → `InvalidResponseError`.
  - Non-2xx → `InvalidResponseError`, made exactly once.
  - Connection failure → `ConnectionError`, attempted twice.
  - Custom `endpoint:` is honored in the request URL; default `http://localhost:11434` is used when `endpoint` is `nil`.

`GROQ_API_KEY` is controlled in specs by stubbing `ENV` rather than adding a new gem. Prior art for service-object specs and WebMock usage: `app/services/supabase_auth/verifier.rb` for the module/error/`.call` conventions, and `spec/support/webmock.rb` for the net-connect policy.

## Out of Scope

- The ticket-generation pipeline itself (Phase 5) and any prompt construction — this PRD delivers only the transport/contract building block.
- **Streaming** responses. Ollama is explicitly forced to `stream: false`; no token streaming for either provider.
- **Tuning parameters** (temperature, top_p, max_tokens, stop sequences, seed). Payloads stay minimal; these can be threaded through later without changing the public method shape.
- **Logging, metrics, and instrumentation** hooks.
- **Async / background execution.** `chat` is synchronous; callers wrap it in a job if they need async.
- **Backoff / multiple retries.** Exactly one immediate retry on connection errors; no exponential backoff.
- **Model validation** — the client does not check that `model` is valid for the chosen provider; it forwards whatever it's given.
- **Response caching** and rate-limit handling (e.g. honoring `Retry-After` on a 429 — a 429 is just an `InvalidResponseError` for now).

## Further Notes

- **Why one class is both factory and base:** it mirrors the existing `SupabaseAuth::Verifier` "hide the machinery behind one class" convention, keeps the file set exactly as specified (`client.rb`, `groq_client.rb`, `ollama_client.rb`), and puts the resilience logic (retry + error mapping) in one place so it can't drift between providers. The template-method split (subclass supplies URL/body/headers/extraction; base owns transport/retry/errors/parsing) is the seam between "what differs per provider" and "what's identical."
- **Why `ArgumentError` for unknown providers** instead of an `LLM::Error`: passing a bad provider is a programming error at the call site, categorically different from a backend being down or misbehaving. Callers rescuing `LLM::Error` should not accidentally swallow it. In practice `provider` originates from the `Project` enum, which already constrains it to `groq`/`ollama`.
- **Why JSON mode parses server-side:** the directive (`response_format` / `format: "json"`) increases the odds of valid JSON but does not guarantee it. Parsing inside the service — and converting a parse failure into `InvalidResponseError` — means a Hash return is always a real guarantee, and callers never write defensive parsing.
- **Why no retry on 4xx/5xx:** a non-2xx is a definitive answer (bad key, bad request, server error). Retrying doubles latency (up to another 60s) with no expected change in outcome. Only ambiguous connection-class failures, which may be transient, are retried.
- **Assumption:** `GROQ_API_KEY` is provided via environment (already documented in `.env.example`); production sets it as a real env var. Test isolation is achieved by stubbing `ENV`.
- **Forward compatibility:** when generation needs tuning params or streaming, they extend the `chat` signature / payload builders additively without breaking the two-error contract or the factory shape.
