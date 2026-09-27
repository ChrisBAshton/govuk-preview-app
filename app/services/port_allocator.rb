require "socket"

class PortAllocator
  RANGE = (ENV.fetch("PREVIEW_APP_PORT_RANGE_START", 20_000).to_i..
            ENV.fetch("PREVIEW_APP_PORT_RANGE_END", 20_999).to_i)

  class NoPortsAvailableError < StandardError; end

  def self.allocate
    used_ports = Preview.where.not(port: nil).pluck(:port).to_set

    RANGE.each do |port|
      next if used_ports.include?(port)
      next unless free?(port)

      return port
    end

    raise NoPortsAvailableError, "No free port in #{RANGE} (all in use or bound by another process)"
  end

  def self.free?(port)
    TCPServer.new("127.0.0.1", port).close
    true
  rescue Errno::EADDRINUSE
    false
  end
end
