require "rails_helper"

RSpec.describe Phase, type: :model do
  it "is valid with factory defaults" do
    expect(build(:phase)).to be_valid
  end

  it "belongs to a project" do
    expect(create(:phase).project).to be_a(Project)
  end

  it "is destroyed when its project is destroyed" do
    phase = create(:phase)

    expect { phase.project.destroy }.to change(Phase, :count).by(-1)
  end

  it "destroys its tickets when destroyed" do
    phase = create(:phase)
    create(:ticket, phase: phase)

    expect { phase.destroy }.to change(Ticket, :count).by(-1)
  end

  it "orders tickets by position" do
    phase = create(:phase)
    second = create(:ticket, phase: phase, position: 1)
    first = create(:ticket, phase: phase, position: 0)

    expect(phase.tickets).to eq([first, second])
  end

  it "requires a title, number, and position" do
    expect(build(:phase, title: nil)).not_to be_valid
    expect(build(:phase, number: nil)).not_to be_valid
    expect(build(:phase, position: nil)).not_to be_valid
  end
end
