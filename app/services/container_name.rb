require "digest"

# Builds the Docker container name for a preview (or its database), which
# doubles as its DNS hostname via Docker's embedded resolver - and DNS
# labels are capped at 63 octets (RFC 1035). A long branch name, especially
# multiplied by a dependency's "-for-<parent-slug>" suffix (see
# Preview#generate_slug), can push the naive "prefix-slug[-suffix]" name
# past that - silently breaking cross-container hostname resolution (e.g.
# DatabaseRunner's start! and DockerRunner's migrate! reaching each other),
# even though same-container tools like `docker exec <name>` still work
# fine (no DNS involved, just the local Docker daemon's own name lookup).
module ContainerName
  PREFIX = "govuk-preview-app-".freeze
  MAX_LENGTH = 63
  DIGEST_LENGTH = 8

  def self.for(slug, suffix: "")
    name = "#{PREFIX}#{slug}#{suffix}"
    return name if name.length <= MAX_LENGTH

    digest = Digest::SHA256.hexdigest(slug).first(DIGEST_LENGTH)
    truncated_length = MAX_LENGTH - PREFIX.length - DIGEST_LENGTH - 1 - suffix.length
    "#{PREFIX}#{slug[0, truncated_length]}-#{digest}#{suffix}"
  end
end
