module Github
  # Builds an LLM-ready snapshot of a repository: a filtered file tree, the
  # decoded README, the language breakdown, and a truncated flag. This is the
  # context a later prompt-building step feeds to the LLM so it can write a plan
  # grounded in the real codebase.
  class RepoContext
    # Directory names that never carry planning signal.
    EXCLUDED_DIRS = %w[node_modules .git dist build vendor].freeze

    # Image and font file extensions: binary assets with no planning value.
    EXCLUDED_EXTENSIONS = %w[
      .png .jpg .jpeg .gif .svg .ico .webp .woff .woff2 .ttf .eot .otf
    ].freeze

    # Blobs larger than this are too big to be worth the context budget.
    MAX_FILE_SIZE = 100_000 # bytes

    # Cap on the number of tree entries returned; keeps a monorepo from blowing
    # the LLM context window. Applying the cap marks the result truncated.
    MAX_TREE_ENTRIES = 1_000

    # How long a repo's context stays cached. The shape is public per-repo, so
    # the cache is keyed by repo (not user) and shared across callers. A raised
    # build is never cached — Rails.cache.fetch only stores the block's return.
    CACHE_TTL = 10.minutes

    def self.build(user, owner, repo)
      Rails.cache.fetch("github:repo_context:#{owner}/#{repo}", expires_in: CACHE_TTL) do
        new(user, owner, repo).build
      end
    end

    def initialize(user, owner, repo)
      @client = Client.new(user)
      @owner = owner
      @repo = repo
    end

    def build
      default_branch = @client.repo(@owner, @repo).fetch("default_branch")
      raw = @client.tree(@owner, @repo, default_branch)
      filtered = filter_tree(Array(raw["tree"]))
      capped = filtered.first(MAX_TREE_ENTRIES)

      {
        tree: capped,
        readme: decode_readme(@client.readme(@owner, @repo)),
        languages: @client.languages(@owner, @repo),
        truncated: !!raw["truncated"] || filtered.size > capped.size
      }
    end

    private

    # Keep only source-relevant file (blob) paths, returning an array of path
    # strings.
    def filter_tree(entries)
      entries.filter_map do |entry|
        next unless entry["type"] == "blob"

        path = entry["path"].to_s
        next if excluded_dir?(path)
        next if path.end_with?(".lock")
        next if EXCLUDED_EXTENSIONS.any? { |ext| path.downcase.end_with?(ext) }
        next if entry["size"].to_i > MAX_FILE_SIZE

        path
      end
    end

    def excluded_dir?(path)
      (path.split("/") & EXCLUDED_DIRS).any?
    end

    # README comes back base64-encoded; nil when the repo has no README.
    def decode_readme(readme)
      return nil if readme.nil?

      Base64.decode64(readme["content"].to_s).force_encoding("UTF-8")
    end
  end
end
