class PreviewsWakeJob < JobBase
  def perform(preview_id)
    preview = Preview.find(preview_id)
    PreviewSleeper.new(preview).wake! if preview.sleeping? || preview.waking?
  end
end
