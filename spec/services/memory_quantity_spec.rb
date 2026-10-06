require "rails_helper"

RSpec.describe MemoryQuantity do
  it "converts binary and decimal Kubernetes memory quantities to whole mebibytes" do
    expect(described_class.to_mi("384Mi")).to eq(384)
    expect(described_class.to_mi("1Gi")).to eq(1024)
    expect(described_class.to_mi("1.5Gi")).to eq(1536)
    expect(described_class.to_mi("2048Ki")).to eq(2)
    expect(described_class.to_mi("0")).to eq(0)
    expect(described_class.to_mi("1G")).to eq(954)
  end

  it "rejects anything else" do
    expect { described_class.to_mi("lots") }.to raise_error(ArgumentError)
  end
end
