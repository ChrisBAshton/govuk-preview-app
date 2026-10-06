class PreviewsSleepJob < JobBase
  def perform(preview_id)
    preview = Preview.find(preview_id)
    PreviewSleeper.new(preview).sleep! if preview.running?
  end
end
