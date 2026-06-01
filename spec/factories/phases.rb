FactoryBot.define do
  factory :phase do
    project
    sequence(:number) { |n| n }
    sequence(:position) { |n| n - 1 }
    title { "Phase #{number}" }
    description { "What this phase delivers." }
  end
end
