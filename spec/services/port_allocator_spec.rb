require "rails_helper"

RSpec.describe PortAllocator do
  describe ".allocate" do
    before do
      allow(described_class).to receive(:free?).and_return(true)
    end

    it "returns the first port in the range when nothing is allocated" do
      expect(described_class.allocate).to eq(described_class::RANGE.first)
    end

    it "skips ports already held by an active preview" do
      create(:preview, port: described_class::RANGE.first)

      expect(described_class.allocate).to eq(described_class::RANGE.first + 1)
    end

    it "skips ports that aren't actually free" do
      allow(described_class).to receive(:free?).with(described_class::RANGE.first).and_return(false)

      expect(described_class.allocate).to eq(described_class::RANGE.first + 1)
    end

    it "raises if no port in the range is available" do
      allow(described_class).to receive(:free?).and_return(false)

      expect { described_class.allocate }.to raise_error(described_class::NoPortsAvailableError)
    end
  end

  describe ".free?" do
    it "is true for a port nothing is bound to" do
      free_port = described_class::RANGE.first

      expect(described_class.free?(free_port)).to be true
    end

    it "is false for a port something is already bound to" do
      server = TCPServer.new("127.0.0.1", 0)
      bound_port = server.addr[1]

      expect(described_class.free?(bound_port)).to be false
    ensure
      server&.close
    end
  end
end
