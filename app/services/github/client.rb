module Github
  # Thin authenticated wrapper over the GitHub REST API on behalf of a user.
  # Built on HTTParty to match the LLM::Client convention, including the
  # single-retry-on-connection-error idiom and a Github::-namespaced error
  # taxonomy that mirrors LLM::.
  class Client
    BASE_URL = "https://api.github.com".freeze

    TIMEOUT = 30 # seconds, applied to both open and read

    # Transport/socket failures that may be transient and are worth one retry.
    # A non-2xx HTTP status is NOT in this list — that is a definitive answer.
    CONNECTION_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
      Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError, Timeout::Error
    ].freeze

    def initialize(user)
      @user = user
    end

    # The current user's repositories, most-recently-updated first.
    def repos
      get("/user/repos", query: { sort: "updated", per_page: 100 })
    end

    # A single repository's metadata (used for default_branch).
    def repo(owner, repo)
      get("/repos/#{owner}/#{repo}")
    end

    # The recursive git tree for a branch: { "tree" => [...], "truncated" => bool }.
    def tree(owner, repo, branch)
      get("/repos/#{owner}/#{repo}/git/trees/#{branch}", query: { recursive: 1 })
    end

    # The repo's README object ({ "content" => base64, "encoding" => "base64" }),
    # or nil when the repo has no README (GitHub 404).
    def readme(owner, repo)
      get("/repos/#{owner}/#{repo}/readme")
    rescue NotFoundError
      nil
    end

    # The repo's language breakdown, e.g. { "Ruby" => 12345 }.
    def languages(owner, repo)
      get("/repos/#{owner}/#{repo}/languages")
    end

    private

    # Issues an authenticated GET and returns the parsed JSON body. Maps GitHub's
    # status codes and transport failures onto the Github:: error taxonomy.
    def get(path, query: {})
      ensure_token!
      response = request(path, query)
      handle_status(response)
      parse_body(response)
    end

    def request(path, query)
      attempts = 0
      begin
        attempts += 1
        HTTParty.get(
          "#{BASE_URL}#{path}",
          query: query,
          headers: headers,
          timeout: TIMEOUT
        )
      rescue *CONNECTION_ERRORS => e
        retry if attempts < 2
        raise ConnectionError, "could not reach GitHub: #{e.message}"
      end
    end

    def handle_status(response)
      return if response.success?

      case response.code
      when 401
        raise UnauthorizedError, "GitHub token invalid"
      when 403, 404
        raise NotFoundError, "GitHub resource not found"
      else
        raise InvalidResponseError, "GitHub returned HTTP #{response.code}: #{response.body.to_s[0, 500]}"
      end
    end

    def parse_body(response)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise InvalidResponseError, "GitHub returned an unparseable body: #{e.message}"
    end

    def headers
      {
        "Authorization" => "Bearer #{@user.github_access_token}",
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28"
      }
    end

    # Fail fast before any network call when the user has no GitHub token: a
    # refreshed Supabase session can omit provider_token.
    def ensure_token!
      raise UnauthorizedError, "no GitHub token" if @user.github_access_token.blank?
    end
  end
end
