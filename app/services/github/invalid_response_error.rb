module Github
  # GitHub answered but the answer was unusable: an unexpected non-2xx status or
  # an unparseable body.
  class InvalidResponseError < Error; end
end
