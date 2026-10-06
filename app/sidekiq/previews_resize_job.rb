class PreviewsResizeJob < JobBase
  def perform(preview_id, full_stack)
    PreviewResizer.new(Preview.find(preview_id)).resize!(full_stack:)
  end
end
