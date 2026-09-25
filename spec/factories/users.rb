FactoryBot.define do
  factory :user do
    sequence(:uid) { |n| "uid-#{n}" }
    sequence(:email) { |n| "user-#{n}@example.com" }
    name { "Test User" }
    permissions { %w[signin] }
  end
end
