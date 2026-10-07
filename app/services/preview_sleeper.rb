# Puts a whole preview stack (a top-level preview and every dependency
# preview beneath it) to sleep, and wakes it up again.
#
# Sleeping scales every Deployment and database StatefulSet in the stack to
# zero, which frees all of its memory (see PreviewCapacity) while keeping
# everything else: Services (so every address stays the same), ConfigMaps,
# images already on the node, and database volumes - so a woken preview
# still has everything that had been published into it. Waking scales them
# back up, databases first: no image pulls, migrations or seeds, so it's
# mostly the time its apps take to boot.
class PreviewSleeper
  WAKE_ERRORS = [PreviewCapacity::AtCapacityError, KubernetesApi::Error].freeze

  attr_reader :root

  def initialize(root, api: KubernetesApi.new)
    @root = root
    @api = api
  end

  def sleep!
    previews = root.tree
    previews.each { |preview| scale(preview, 0) }
    StackRedis.new(root, api: api).scale!(0)
    Preview.where(id: previews.map(&:id)).update_all(status: "sleeping", status_message: nil, updated_at: Time.current)
  end

  # Until the stack's pods are actually gone - only then does the memory
  # they'd requested count as free again.
  def wait_until_asleep!(timeout: 180)
    deadline = Time.current + timeout
    previews = root.tree
    pause until PreviewCapacity.pods_for(api, previews).empty? || Time.current > deadline
  end

  def wake!
    previews = root.tree
    PreviewCapacity.make_room_for!(root)
    Preview.where(id: previews.map(&:id)).update_all(status: "waking", status_message: nil, updated_at: Time.current)

    StackRedis.new(root, api: api).scale!(1)
    databases = previews.filter_map { |preview| database_runner(preview) }
    databases.each { |database| database.scale!(1) }
    databases.each(&:wait_until_ready!)

    runners = previews.map { |preview| KubernetesRunner.new(preview, api: api) }
    runners.each { |runner| runner.scale!(1) }
    runners.each(&:wait_until_running!)

    Preview.where(id: previews.map(&:id)).update_all(status: "running", status_message: nil, updated_at: Time.current)
  rescue *WAKE_ERRORS => e
    # Back to sleep rather than left half-awake, holding on to memory - with
    # the reason shown on the preview, and another visit tries again.
    sleep!
    root.update_column(:status_message, "Couldn't wake up: #{e.message}".truncate(255))
  end

private

  attr_reader :api

  def scale(preview, replicas)
    KubernetesRunner.new(preview, api: api).scale!(replicas)
    database_runner(preview)&.scale!(replicas)
  rescue KubernetesApi::NotFound
    nil # e.g. a dependency that failed before its objects were created
  end

  def database_runner(preview)
    database = GovukApps.find(preview.app_name).database
    KubernetesDatabaseRunner.new(preview, database, api: api) if database
  end

  def pause
    sleep 3
  end
end
