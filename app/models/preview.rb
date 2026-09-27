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

  # http locally (no TLS in front of nginx here); integration will run with
  # APP_PREVIEW_SCHEME=https once there's a real Ingress/ACM cert in front.
  def self.scheme
    ENV.fetch("APP_PREVIEW_SCHEME", "http")
  end

  def hostname
    "#{slug}.#{self.class.base_domain}"
  end

  def url
    "#{self.class.scheme}://#{hostname}"
  end

private

  def generate_slug
    return if app_name.blank? || branch.blank?

    self.slug ||= "#{app_name}-#{branch}".parameterize
  end
end
