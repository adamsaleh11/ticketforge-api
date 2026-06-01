module Github
  # The GitHub token is missing, expired, or revoked (GitHub 401). Surfaced to
  # the user as an actionable "sign in again" 401.
  class UnauthorizedError < Error; end
end
