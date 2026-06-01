require "rails_helper"

RSpec.describe Project, type: :model do
  it "is valid with factory defaults" do
    expect(build(:project)).to be_valid
  end

  it "belongs to a user" do
    expect(create(:project).user).to be_a(User)
  end

  it "is destroyed when its owner is destroyed" do
    project = create(:project)

    expect { project.user.destroy }.to change(Project, :count).by(-1)
  end

  it "requires a name" do
    project = build(:project, name: nil)
    expect(project).not_to be_valid
    expect(project.errors[:name]).to be_present
  end

  it "rejects a name longer than 255 characters" do
    expect(build(:project, name: "a" * 256)).not_to be_valid
  end

  it "requires an llm_model" do
    expect(build(:project, llm_model: nil)).not_to be_valid
  end

  it "allows a nil github_repo_full_name" do
    expect(build(:project, github_repo_full_name: nil)).to be_valid
  end

  it "rejects a malformed github_repo_full_name" do
    expect(build(:project, github_repo_full_name: "not-a-repo")).not_to be_valid
  end

  it "accepts an owner/repo github_repo_full_name" do
    expect(build(:project, github_repo_full_name: "shilpatel/myrepo")).to be_valid
  end

  it "rejects an unknown llm_provider" do
    expect { build(:project, llm_provider: "openai") }
      .to raise_error(ArgumentError, /not a valid llm_provider/)
  end

  it "defaults status to draft" do
    expect(Project.new.status).to eq("draft")
  end

  it "exposes the expected provider and status enum values" do
    expect(Project.llm_providers.keys).to contain_exactly("groq", "ollama")
    expect(Project.statuses.keys).to contain_exactly("draft", "generating", "ready", "failed")
  end
end
