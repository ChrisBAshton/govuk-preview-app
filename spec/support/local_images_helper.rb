module LocalImagesHelper
  # As in local development (kubernetes/local/preview-app.yaml).
  def enable_local_images
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PREVIEW_APP_LOCAL_IMAGES").and_return("true")
  end
end

RSpec.configure { |config| config.include LocalImagesHelper }
