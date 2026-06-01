class TicketGenerator
  # Turns a Github::RepoContext hash ({ tree:, readme:, languages:, truncated: })
  # into a prompt fragment within a fixed character budget. Budgets approximate
  # tokens at ~4 chars/token: ~3000 tokens of file tree, ~1000 of README. The
  # tree is cut on whole lines (never a half path); truncation is marked so the
  # model knows the view is partial.
  class RepoContextFormatter
    TREE_CHAR_BUDGET = 12_000   # ~3000 tokens
    README_CHAR_BUDGET = 4_000  # ~1000 tokens

    def initialize(context)
      @context = context
    end

    def to_prompt
      sections = ["## Repository context", languages_section, tree_section]
      sections << readme_section if readme.present?
      sections.compact.join("\n\n")
    end

    private

    def languages_section
      langs = @context[:languages]
      return "Languages: (unknown)" if langs.blank?

      "Languages: #{langs.keys.join(', ')}"
    end

    def tree_section
      joined = Array(@context[:tree]).join("\n")
      clipped = clip_lines(joined, TREE_CHAR_BUDGET)
      truncated = clipped.length < joined.length || @context[:truncated]

      "File tree#{truncated ? ' (truncated)' : ''}:\n#{clipped}"
    end

    def readme_section
      clipped = readme.to_s[0, README_CHAR_BUDGET]
      truncated = readme.to_s.length > README_CHAR_BUDGET

      "README#{truncated ? ' (truncated)' : ''}:\n#{clipped}"
    end

    def readme
      @context[:readme]
    end

    # Keep whole lines only, never exceeding the budget.
    def clip_lines(text, budget)
      return text if text.length <= budget

      kept = +""
      text.each_line do |line|
        break if kept.length + line.length > budget

        kept << line
      end
      kept.chomp
    end
  end
end
