class Preview < ApplicationRecord
  enum :status, {
    queued: "queued",
    checking_out: "checking_out",
    building: "building",
    starting: "starting",
    running: "running",
    stopping: "stopping",
    failed: "failed",
  }, default: :queued

  validates :app_name, presence: true, inclusion: { in: -> { GovukApps.app_names } }
  validates :branch, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :generate_slug, on: :create

  def hostname
    "#{slug}.#{ENV.fetch('APP_PREVIEW_BASE_DOMAIN', 'app-preview.test')}"
  end

private

  def generate_slug
    return if app_name.blank? || branch.blank?

    self.slug ||= "#{app_name}-#{branch}".parameterize
  end
end
