require "rails_helper"

RSpec.describe Ticket, type: :model do
  it "is valid with factory defaults" do
    expect(build(:ticket)).to be_valid
  end

  it "belongs to a phase" do
    expect(create(:ticket).phase).to be_a(Phase)
  end

  it "requires a title and body" do
    expect(build(:ticket, title: nil)).not_to be_valid
    expect(build(:ticket, body: nil)).not_to be_valid
  end

  it "defaults status to pending" do
    expect(Ticket.new.status).to eq("pending")
  end

  it "exposes the expected repo and status enum values" do
    expect(Ticket.repos.keys).to contain_exactly("frontend", "backend", "fullstack", "devops")
    expect(Ticket.statuses.keys).to contain_exactly("pending", "in_progress", "done")
  end

  it "rejects an unknown repo" do
    expect { build(:ticket, repo: "mobile") }
      .to raise_error(ArgumentError, /not a valid repo/)
  end
end
