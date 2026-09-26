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

  def self.base_domain
    ENV.fetch("APP_PREVIEW_BASE_DOMAIN", "govuk-app-preview.dev.gov.uk")
  end

  def hostname
    "#{slug}.#{self.class.base_domain}"
  end

private

  def generate_slug
    return if app_name.blank? || branch.blank?

    self.slug ||= "#{app_name}-#{branch}".parameterize
  end
end
