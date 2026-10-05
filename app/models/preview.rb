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

  belongs_to :parent, class_name: "Preview", optional: true
  # No `dependent: :destroy` - a dependency preview owns a container/DB/
  # checkout that an AR callback can't clean up. PreviewDestroyer stops
  # those explicitly before destroying the row.
  has_many :dependents, class_name: "Preview", foreign_key: :parent_id, inverse_of: :parent

  validates :app_name, presence: true, inclusion: { in: -> { GovukApps.app_names } }
  validates :branch, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :generate_slug, on: :create
  before_validation :generate_public_hostname, on: :create

  def self.base_domain
    ENV.fetch("PREVIEW_APP_BASE_DOMAIN", "govuk-preview-app.dev.gov.uk")
  end

  # http locally (no TLS in front of nginx here); integration will run with
  # PREVIEW_APP_SCHEME=https once there's a real Ingress/ACM cert in front.
  def self.scheme
    ENV.fetch("PREVIEW_APP_SCHEME", "http")
  end

  # Same env var nginx's own port mapping uses (docker-compose.yml) - kept
  # in sync so links rendered here are directly clickable locally, while
  # staying blank for a real deployment (fronted by a real Ingress on the
  # standard ports, no override needed).
  def self.external_port
    ENV["PREVIEW_APP_NGINX_PORT"]
  end

  # Whether this preview's app is allowed to be hostname-routable even when
  # it's a dependency (see HostRouter) - only for genuinely read-only,
  # non-mutating APIs (e.g. Content Store), never for an unauthenticated,
  # state-mutating one (e.g. Publishing API).
  def publicly_readable?
    GovukApps.find(app_name)&.publicly_readable || false
  end

  # A publicly_readable dependency (e.g. Content Store) is reachable at this
  # short, randomised hostname instead of its real (potentially long, since
  # it chains through every parent in its dependency tree) slug - there's no
  # value in the public URL expressing those relationships, and a random
  # token per instance keeps two separate previews' Content Stores from ever
  # looking like the same shared one (see HostRouter).
  def hostname
    "#{public_hostname || slug}.#{self.class.base_domain}"
  end

  def url
    port_suffix = self.class.external_port.presence && ":#{self.class.external_port}"
    "#{self.class.scheme}://#{hostname}#{port_suffix}"
  end

private

  def generate_slug
    return if app_name.blank? || branch.blank?

    base = "#{app_name}-#{branch}"
    # A dependency preview is dedicated to its parent (never shared across
    # parents), so its slug needs to be unique per-parent, not just per
    # app+branch - otherwise two previews both depending on
    # publishing-api/main would collide.
    base = "#{base}-for-#{parent.slug}" if parent.present?
    self.slug ||= base.parameterize
  end

  def generate_public_hostname
    # Only for a dependency - a standalone top-level preview already gets a
    # perfectly good, readable hostname from its own slug, and has none of
    # the "slug reveals its whole dependency chain" problem this solves.
    return unless parent.present? && publicly_readable?

    loop do
      candidate = "#{app_name}-#{SecureRandom.alphanumeric(7).downcase}".parameterize
      next if self.class.exists?(public_hostname: candidate)

      self.public_hostname = candidate
      break
    end
  end
end
