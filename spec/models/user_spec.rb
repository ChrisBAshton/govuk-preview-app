require "rails_helper"

RSpec.describe User do
  it "has a valid factory" do
    expect(build(:user)).to be_valid
  end

  describe "#has_permission?" do
    it "is true when the permission is present" do
      user = build(:user, permissions: %w[signin edit])

      expect(user.has_permission?("edit")).to be true
    end

    it "is false when the permission is absent" do
      user = build(:user, permissions: %w[signin])

      expect(user.has_permission?("edit")).to be false
    end
  end
end
