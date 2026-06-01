module Github
  # GitHub returned 404 (or 403 for an inaccessible private repo): the repo does
  # not exist or the token cannot see it.
  class NotFoundError < Error; end
end
