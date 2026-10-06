# Makes sure there's room in the previews namespace for a whole preview
# stack before it's built or woken, by putting the least recently used
# other stacks to sleep (see PreviewSleeper) until there is.
#
# "Room" is the namespace's ResourceQuota (kubernetes/previews/
# resource-quota.yaml): Kubernetes refuses to create any pod that would
# take it over its memory limits, so a stack that doesn't fit would
# otherwise just sit there half-started. On integration the quota is the
# cost cap - the cluster autoscaler adds nodes for anything under it. Locally
# the same quota is set to what the single kind node can actually hold
# (kubernetes/local/kustomization.yaml), so the same rule stops it running
# out of memory.
#
# How much a stack needs is worked out from what KubernetesRunner and
# KubernetesDatabaseRunner request for each of its pods - not measured -
# because that's what Kubernetes itself schedules and charges against the
# quota.
class PreviewCapacity
  class AtCapacityError < StandardError; end

  QUOTA_NAME = "previews".freeze
  RESOURCES = %w[requests.memory limits.memory].freeze
  # A stack used this recently is never put to sleep to make room - someone
  # is probably still looking at it.
  RECENTLY_USED = 15.minutes

  def self.make_room_for!(root, building: false)
    new(root, building:).make_room!
  end

  # Every non-finished pod belonging to any of these previews.
  def self.pods_for(api, previews)
    selector = "govuk-preview-app/preview-id in (#{previews.map(&:id).join(',')})"
    api.get(api.path("v1", "pods"), labelSelector: selector).fetch("items", [])
      .reject { |pod| %w[Succeeded Failed].include?(pod.dig("status", "phase")) }
  end

  def initialize(root, building: false, api: KubernetesApi.new)
    @root = root
    @building = building
    @api = api
  end

  def make_room!
    return if (missing = shortfall).empty?

    made_room = sleep_candidates.find do |candidate|
      Rails.logger.info("PreviewCapacity: sleeping #{candidate.slug} to make room for #{root.slug}")
      sleeper = PreviewSleeper.new(candidate, api: api)
      sleeper.sleep!
      sleeper.wait_until_asleep!

      (missing = shortfall).empty?
    end
    return if made_room

    raise AtCapacityError,
          "At capacity: this preview needs #{missing.values.max}Mi more memory than is free, and every other " \
          "preview has either been used in the last #{RECENTLY_USED.inspect} or is already asleep. Try again " \
          "later, or delete a preview that's no longer needed."
  end

  # Mebibytes still needed beyond what the quota has free, per resource -
  # empty when the whole stack fits (or there's no quota to fit within).
  def shortfall
    quota = read_quota
    return {} unless quota

    needed = stack_needs
    in_use = stack_usage

    RESOURCES.filter_map { |resource|
      hard = quota.dig("status", "hard", resource)
      next unless hard

      free = MemoryQuantity.to_mi(hard) - MemoryQuantity.to_mi(quota.dig("status", "used", resource) || "0")
      missing = needed[resource] - in_use[resource] - free
      [resource, missing] if missing.positive?
    }.to_h
  end

private

  attr_reader :root, :building, :api

  def read_quota
    api.get(api.path("v1", "resourcequotas", QUOTA_NAME))
  rescue KubernetesApi::NotFound
    nil
  end

  # Everything the whole stack asks for once running - plus, while it's
  # being built, room for the one migrate/seed/setup Job pod that runs at
  # a time.
  def stack_needs
    pods = [root.app_name, *GovukApps.dependency_tree(root.app_name)].flat_map do |app_name|
      app = GovukApps.find(app_name)
      app_pods = [KubernetesRunner] * (app.worker_command ? 2 : 1)
      app.database ? [*app_pods, KubernetesDatabaseRunner] : app_pods
    end
    pods << KubernetesRunner if building

    {
      "requests.memory" => pods.sum { |runner| MemoryQuantity.to_mi(runner.memory_request) },
      "limits.memory" => pods.sum { |runner| MemoryQuantity.to_mi(runner.memory_limit) },
    }
  end

  # What this stack's own pods already count against the quota - e.g. the
  # dependencies that had already started before an interrupted build.
  def stack_usage
    containers = self.class.pods_for(api, root.tree).flat_map { |pod| pod.dig("spec", "containers").to_a }

    {
      "requests.memory" => containers.sum { |c| MemoryQuantity.to_mi(c.dig("resources", "requests", "memory") || "0") },
      "limits.memory" => containers.sum { |c| MemoryQuantity.to_mi(c.dig("resources", "limits", "memory") || "0") },
    }
  end

  # Least recently used first; never-visited previews (e.g. ones that
  # predate tracking visits) count as least recently used of all.
  def sleep_candidates
    Preview.where(parent_id: nil, status: :running).where.not(id: root.id)
      .where("last_accessed_at IS NULL OR last_accessed_at < ?", RECENTLY_USED.ago)
      .order(Arel.sql("last_accessed_at ASC NULLS FIRST, id ASC"))
  end
end
