require "rails_helper"

RSpec.describe TicketGenerator::RepoContextFormatter do
  def context(tree: [], readme: nil, languages: {}, truncated: false)
    { tree: tree, readme: readme, languages: languages, truncated: truncated }
  end

  it "renders the file tree, languages, and README" do
    text = described_class.new(
      context(tree: %w[app/main.rb lib/util.rb], readme: "# My Project", languages: { "Ruby" => 100 })
    ).to_prompt

    expect(text).to include("app/main.rb", "lib/util.rb")
    expect(text).to include("Ruby")
    expect(text).to include("# My Project")
  end

  it "marks the tree as truncated when the byte budget is exceeded" do
    big_tree = Array.new(5_000) { |i| "app/models/file_number_#{i}.rb" }

    text = described_class.new(context(tree: big_tree)).to_prompt

    expect(text).to include("truncated")
    # whole lines only — never a half-cut path
    tree_section = text.lines.select { |l| l.start_with?("app/models/file_number_") }
    expect(tree_section).to all(match(/file_number_\d+\.rb\n?\z/))
  end

  it "marks the tree truncated when the source context was already truncated" do
    text = described_class.new(context(tree: %w[a.rb], truncated: true)).to_prompt

    expect(text).to include("truncated")
  end

  it "truncates an oversized README" do
    readme = "x" * 10_000

    text = described_class.new(context(readme: readme)).to_prompt

    expect(text).to include("truncated")
    expect(text.length).to be < readme.length
  end

  it "omits the README section when there is no README" do
    text = described_class.new(context(tree: %w[a.rb], readme: nil)).to_prompt

    expect(text.downcase).not_to include("readme")
  end
end
