class PreviewsCreateJob < JobBase
  def perform(preview_id)
    preview = Preview.find(preview_id)

    checkout = Checkout.new(preview)
    docker = DockerRunner.new(preview)

    preview.update!(status: :checking_out)
    checkout_path = checkout.checkout!

    preview.update!(status: :building)
    docker.build!(checkout_path)

    preview.update!(status: :starting, port: PortAllocator.allocate)
    container_id = docker.start!

    preview.update!(status: :running, container_id: container_id)
  rescue Checkout::GitError, DockerRunner::DockerError, PortAllocator::NoPortsAvailableError => e
    preview.update!(status: :failed, status_message: e.message.truncate(255))
  end
end
