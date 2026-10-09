require "digest"

class Preview < ApplicationRecord
  # The slug doubles as a DNS label (see #hostname) - capped at 63 chars by
  # RFC 1035, same limit ContainerName truncates Kubernetes object names to.
  # A long branch (e.g. a local: tag with a -dirty-<timestamp> suffix),
  # especially multiplied by a dependency's "-for-<parent-slug>" suffix, can
  # push the naive "app-branch[-for-parent]" slug past that - truncated and
  # made unique with a digest, so the hostname this becomes always resolves.
  MAX_SLUG_LENGTH = 63
  SLUG_DIGEST_LENGTH = 8
  enum :status, {
    queued: "queued",
    # Waiting for the branch's image to be pushed by its own GitHub Actions
    # workflow (see ImageResolver).
    waiting_for_image: "waiting_for_image",
    starting: "starting",
    running: "running",
    # Scaled down to free up room, with everything kept - see
    # PreviewSleeper. Woken again on the next visit.
    sleeping: "sleeping",
    waking: "waking",
    stopping: "stopping",
    failed: "failed",
  }, default: :queued

  belongs_to :parent, class_name: "Preview", optional: true
  # No `dependent: :destroy` - a dependency preview owns Kubernetes objects
  # (and maybe a database volume) that an AR callback can't clean up.
  # PreviewDestroyer deletes those explicitly before destroying the row.
  has_many :dependents, class_name: "Preview", foreign_key: :parent_id, inverse_of: :parent

  validates :app_name, presence: true, inclusion: { in: -> { GovukApps.app_names } }
  validates :branch, presence: true
  validates :slug, presence: true, uniqueness: true
  validate :branch_is_a_usable_source

  before_validation :generate_slug, on: :create
  before_validation :ignore_full_stack_without_option
  before_validation :generate_public_hostname, on: :create

  # Preview App's own fixed hostname (its admin UI, and where
  # PreviewSignon's OAuth endpoints live) - not necessarily the same
  # domain previews themselves live under, see .base_domain.
  def self.admin_hostname
    ENV.fetch("PREVIEW_APP_BASE_DOMAIN", "govuk-preview-app.dev.gov.uk")
  end

  # The domain previews live under - defaults to admin_hostname (true
  # locally, and wherever PREVIEW_HOSTNAME_BASE_DOMAIN isn't set), but can
  # be pointed elsewhere via PREVIEW_HOSTNAME_BASE_DOMAIN - e.g. on
  # Integration, temporarily, while *.admin_hostname's own wildcard cert
  # doesn't yet exist (see alphagov/govuk-helm-charts#4550).
  def self.base_domain
    ENV.fetch("PREVIEW_HOSTNAME_BASE_DOMAIN", admin_hostname)
  end

  # http locally (nothing terminates TLS in the kind cluster); integration
  # runs with PREVIEW_APP_SCHEME=https behind its real load balancer.
  def self.scheme
    ENV.fetch("PREVIEW_APP_SCHEME", "http")
  end

  # The host port the local kind cluster exposes Preview App on (see
  # kubernetes/local/kind-config.yaml) - so links rendered here are directly
  # clickable locally, while staying blank on integration (standard ports).
  def self.external_port
    ENV["PREVIEW_APP_EXTERNAL_PORT"]
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

  # Whether this preview's app is still in config/govuk_apps.yml. One that's
  # since been removed (or renamed) can't be built, woken or resized any
  # more - only deleted - and code that looks its app up mustn't assume it.
  def app_known?
    GovukApps.find(app_name).present?
  end

  # The top-level preview this one ultimately exists for (itself, if it has
  # no parent) - previews are slept, woken and charged for capacity as a
  # whole stack, via their root.
  def root
    parent.present? ? parent.root : self
  end

  # This preview and every dependency preview beneath it, at any depth.
  def tree
    [self, *dependents.flat_map(&:tree)]
  end

  # When someone last did something with this preview: created, visited,
  # retried, woke, put to sleep or changed its stack size. Only ever set by
  # a person's action - never by anything automatic, like a build finishing
  # or PreviewCapacity putting it to sleep to make room - so it says which
  # previews people are actually using. The previews page lists them by it,
  # newest first, and PreviewCapacity puts the least recently used to sleep
  # first.
  #
  # throttle: visits (see HostRouter) happen on every request, so they only
  # write at most once a minute.
  def record_interaction!(throttle: false)
    return if throttle && last_interacted_at.present? && last_interacted_at > 1.minute.ago

    update_column(:last_interacted_at, Time.current)
  end

  def url
    "#{self.class.scheme}://#{hostname}#{self.class.port_suffix}"
  end

  # Every preview's hostname at once, as a Content Security Policy source -
  # see ConfigOverrides.
  def self.csp_source
    "#{scheme}://*.#{base_domain}#{port_suffix}"
  end

  def self.port_suffix
    external_port.presence && ":#{external_port}"
  end

  # Truncates a parameterized slug to MAX_SLUG_LENGTH, appending a digest of
  # the full, untruncated string so two slugs that only differ after the
  # truncation point still end up distinct - same approach as ContainerName.
  def self.fit_slug(slug)
    return slug if slug.length <= MAX_SLUG_LENGTH

    digest = Digest::SHA256.hexdigest(slug).first(SLUG_DIGEST_LENGTH)
    truncated_length = MAX_SLUG_LENGTH - SLUG_DIGEST_LENGTH - 1
    "#{slug[0, truncated_length]}-#{digest}"
  end

private

  # Only some apps have a full stack that's any different from their core
  # one (see GovukApps.full_stack_option?) - for the rest, there's nothing
  # to switch on.
  def ignore_full_stack_without_option
    self.full_stack = false if full_stack && !GovukApps.full_stack_option?(app_name)
  end

  # A `local:<tag>` branch is an image built from a developer's own
  # checkout (see ImageResolver, bin/preview-build) - only usable locally.
  def branch_is_a_usable_source
    return unless ImageResolver.local?(branch)

    if !ImageResolver.local_images_enabled?
      errors.add(:branch, "can only use a local image in local development")
    elsif !ImageResolver.local_tag(branch).match?(ImageResolver::LOCAL_TAG_FORMAT)
      errors.add(:branch, "has an invalid local image tag")
    end
  end

  def generate_slug
    return if app_name.blank? || branch.blank?

    base = "#{app_name}-#{branch}"
    # A dependency preview is dedicated to its parent (never shared across
    # parents), so its slug needs to be unique per-parent, not just per
    # app+branch - otherwise two previews both depending on
    # publishing-api/main would collide.
    base = "#{base}-for-#{parent.slug}" if parent.present?
    self.slug ||= self.class.fit_slug(base.parameterize)
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
