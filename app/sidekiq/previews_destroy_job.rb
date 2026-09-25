class PreviewsDestroyJob < JobBase
  def perform(preview_id)
    preview = Preview.find(preview_id)

    DockerRunner.new(preview).stop!
    Checkout.new(preview).remove!

    preview.destroy!
  end
end
