require "rails_helper"

RSpec.describe TicketGenerator::Prompts do
  let(:project) { build(:project, name: "Acme", description: "Build a CRM") }

  describe ".system" do
    it "is the fixed senior-engineering-lead prompt with the strict JSON schema" do
      expect(described_class.system).to include("senior engineering lead")
      expect(described_class.system).to include('"phases"')
    end
  end

  describe ".user" do
    it "includes the project name and description" do
      text = described_class.user(project)

      expect(text).to include("Acme")
      expect(text).to include("Build a CRM")
    end

    it "omits the repository-context section when no context is given" do
      expect(described_class.user(project)).not_to include("Repository context")
    end

    it "includes the formatted repository context when given" do
      context = { tree: %w[app/main.rb], readme: "# Readme", languages: { "Ruby" => 1 }, truncated: false }

      text = described_class.user(project, repo_context: context)

      expect(text).to include("Repository context")
      expect(text).to include("app/main.rb")
    end
  end
end
