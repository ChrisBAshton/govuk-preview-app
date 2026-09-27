class PreviewsDestroyJob < JobBase
  def perform(preview_id)
    PreviewDestroyer.new(Preview.find(preview_id)).destroy!
  end
end
