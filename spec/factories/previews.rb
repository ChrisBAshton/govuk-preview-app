FactoryBot.define do
  factory :preview do
    app_name { "frontend" }
    sequence(:branch) { |n| "branch-#{n}" }
  end
end
