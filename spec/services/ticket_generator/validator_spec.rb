require "rails_helper"

RSpec.describe TicketGenerator::Validator do
  def plan(phases: 5, tickets_per_phase: 2)
    {
      "phases" => Array.new(phases) do |p|
        {
          "title" => "Phase #{p + 1}",
          "description" => "Description #{p + 1}",
          "tickets" => Array.new(tickets_per_phase) do |t|
            { "repo" => "backend", "title" => "T#{p}.#{t}", "body" => "body" }
          end
        }
      end
    }
  end

  it "accepts an in-bounds plan" do
    expect { described_class.new(plan(phases: 6, tickets_per_phase: 3)).validate! }
      .not_to raise_error
  end

  it "accepts the boundary sizes" do
    expect { described_class.new(plan(phases: 8, tickets_per_phase: 5)).validate! }.not_to raise_error
    expect { described_class.new(plan(phases: 5, tickets_per_phase: 2)).validate! }.not_to raise_error
  end

  it "rejects a non-hash plan" do
    expect { described_class.new("nope").validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
  end

  it "rejects too few or too many phases" do
    expect { described_class.new(plan(phases: 4)).validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
    expect { described_class.new(plan(phases: 9)).validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
  end

  it "rejects a phase with out-of-range ticket counts" do
    expect { described_class.new(plan(tickets_per_phase: 1)).validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
    expect { described_class.new(plan(tickets_per_phase: 6)).validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
  end

  it "rejects an invalid repo" do
    bad = plan
    bad["phases"][0]["tickets"][0]["repo"] = "mobile"
    expect { described_class.new(bad).validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
  end

  it "rejects a ticket missing a body" do
    bad = plan
    bad["phases"][0]["tickets"][0]["body"] = ""
    expect { described_class.new(bad).validate! }
      .to raise_error(TicketGenerator::InvalidStructure)
  end
end
