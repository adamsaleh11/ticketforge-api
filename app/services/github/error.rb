module Github
  # Base class for all GitHub client failures. Callers can rescue Github::Error
  # to catch every failure this service raises. Mirrors the LLM::Error taxonomy.
  class Error < StandardError; end
end
