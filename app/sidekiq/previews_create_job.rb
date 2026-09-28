class PreviewsCreateJob < JobBase
  def perform(preview_id)
    PreviewBuilder.new(Preview.find(preview_id)).build!
  end
end
