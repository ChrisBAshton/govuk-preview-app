require "rails_helper"

RSpec.describe ConfigOverrides do
  let(:checkout_path) { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.rm_rf(checkout_path) }

  describe "#write!" do
    it "writes an initializer disabling x_sendfile_header, overriding the database connection, and clearing config.hosts" do
      described_class.new(checkout_path).write!

      content = checkout_path.join("config/initializers/zzz_preview_app_overrides.rb").read

      expect(content).to include("config.action_dispatch.x_sendfile_header = nil")
      expect(content).to include('ActiveRecord::Base.establish_connection(ENV["DATABASE_URL"])')
      expect(content).to include("config.hosts.clear")
    end

    it "creates config/initializers if it doesn't already exist" do
      described_class.new(checkout_path).write!

      expect(checkout_path.join("config/initializers")).to be_a_directory
    end
  end
end
