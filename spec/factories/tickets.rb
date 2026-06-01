FactoryBot.define do
  factory :ticket do
    phase
    sequence(:position) { |n| n - 1 }
    repo { "backend" }
    title { "Implement the thing" }
    body { "Detailed, paste-ready instructions with acceptance criteria." }
    status { "pending" }
  end
end
