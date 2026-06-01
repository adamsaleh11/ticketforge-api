require 'webmock/rspec'

# Disable all real outbound HTTP in the test suite. External services
# (Groq, Ollama, GitHub) must always be stubbed — never hit the network.
WebMock.disable_net_connect!(allow_localhost: true)
