module Github
  # The GitHub API could not be reached: DNS failure, refused connection, reset,
  # or timeout (after the single retry).
  class ConnectionError < Error; end
end
