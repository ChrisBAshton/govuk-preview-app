# Converts a Kubernetes memory quantity ("384Mi", "1Gi", "512M", plain
# bytes...) to whole mebibytes, for adding up and comparing pods' and
# ResourceQuotas' memory - see PreviewCapacity.
module MemoryQuantity
  UNITS = {
    "Ki" => 1024,
    "Mi" => 1024**2,
    "Gi" => 1024**3,
    "Ti" => 1024**4,
    "k" => 1000,
    "M" => 1000**2,
    "G" => 1000**3,
    "T" => 1000**4,
    "" => 1,
  }.freeze

  def self.to_mi(quantity)
    match = quantity.to_s.match(/\A(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|k|M|G|T)?\z/)
    raise ArgumentError, "Unrecognised memory quantity: #{quantity.inspect}" unless match

    (match[1].to_f * UNITS.fetch(match[2].to_s) / 1024**2).ceil
  end
end
