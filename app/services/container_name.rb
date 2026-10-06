require "digest"

# Builds the Kubernetes object name for a preview (or its database, worker,
# etc.) - which doubles as its Service's DNS name, and Kubernetes caps
# Service names at 63 characters (an RFC 1035 DNS label). A long branch
# name, especially multiplied by a dependency's "-for-<parent-slug>" suffix
# (see Preview#generate_slug), can push the naive "prefix-slug[-suffix]"
# name past that, so it's truncated and made unique with a digest.
module ContainerName
  PREFIX = "govuk-preview-app-".freeze
  MAX_LENGTH = 63
  DIGEST_LENGTH = 8

  # max_length: a Kubernetes StatefulSet's name has to leave room for the
  # "-<hash>" Kubernetes itself appends to build its pods'
  # controller-revision-hash label (also capped at 63), so
  # KubernetesDatabaseRunner asks for a shorter name than the DNS limit.
  def self.for(slug, suffix: "", max_length: MAX_LENGTH)
    name = "#{PREFIX}#{slug}#{suffix}"
    return name if name.length <= max_length

    digest = Digest::SHA256.hexdigest(slug).first(DIGEST_LENGTH)
    truncated_length = max_length - PREFIX.length - DIGEST_LENGTH - 1 - suffix.length
    "#{PREFIX}#{slug[0, truncated_length]}-#{digest}#{suffix}"
  end
end
