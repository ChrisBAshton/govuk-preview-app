require "rails_helper"

RSpec.describe ContainerName do
  describe ".for" do
    it "builds a plain prefixed name when it fits within the DNS label limit" do
      expect(described_class.for("frontend-my-branch")).to eq("govuk-preview-app-frontend-my-branch")
    end

    it "appends a suffix before checking the length" do
      expect(described_class.for("frontend-my-branch", suffix: "-db")).to eq("govuk-preview-app-frontend-my-branch-db")
    end

    it "truncates and appends a digest when the name would exceed 63 characters" do
      long_slug = "publishing-api-main-for-whitehall-travel-advice-spike"
      name = described_class.for(long_slug, suffix: "-db")

      expect(name.length).to eq(63)
      expect(name).to start_with("govuk-preview-app-")
      expect(name).to end_with("-db")
    end

    it "truncates to a custom max_length when given one" do
      name = described_class.for("publishing-api-main-for-whitehall-main", suffix: "-db", max_length: 52)

      expect(name.length).to eq(52)
      expect(name).to end_with("-db")
    end

    it "produces distinct names for slugs that only differ after the truncation point" do
      base = "a" * 60
      name_a = described_class.for("#{base}-one")
      name_b = described_class.for("#{base}-two")

      expect(name_a).not_to eq(name_b)
    end
  end
end
