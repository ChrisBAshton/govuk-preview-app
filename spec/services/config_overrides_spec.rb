require "rails_helper"

RSpec.describe ConfigOverrides do
  describe ".content" do
    it "is valid Ruby" do
      expect { RubyVM::InstructionSequence.compile(described_class.content) }.not_to raise_error
    end

    it "reconnects from DATABASE_URL on top of the app's own config, rather than instead of it" do
      expect(described_class.content).to include("configs_for(env_name: Rails.env)", "merge(url: ENV[\"DATABASE_URL\"])")
    end
  end
end
