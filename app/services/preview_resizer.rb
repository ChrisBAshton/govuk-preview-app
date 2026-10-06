# Switches a running top-level preview between the core stack and the full
# stack (see `full_stack_only` in config/govuk_apps.yml), without
# rebuilding what's already there:
#
# - adding the full stack makes room for the extra apps, then lets
#   PreviewBuilder build them and restart anything already running whose
#   dependency addresses change (e.g. Publishing API, from the stand-in
#   sink to its new Content Stores, which it then fills - see
#   `resync_tasks`);
# - removing it deletes those extra apps, then restarts what remains,
#   pointed back at the sink.
#
# Either way every database is kept, so nothing published is lost - except
# what only ever lived in the removed Content Stores, which is re-sent if
# the full stack is added again.
class PreviewResizer
  ADDING = "Adding the full stack…".freeze
  REMOVING = "Removing the full stack…".freeze

  attr_reader :root

  def initialize(root)
    @root = root
  end

  def resize!(full_stack:)
    return unless root.running?

    root.update!(full_stack:, status_message: full_stack ? ADDING : REMOVING)
    if full_stack
      PreviewCapacity.make_room_for!(root)
    else
      # Destroying one also destroys anything beneath it.
      extra_previews.each { |preview| PreviewDestroyer.new(preview).destroy! if Preview.exists?(preview.id) }
    end

    PreviewBuilder.new(root.reload).build!
    root.update!(status_message: nil) if root.reload.running?
  rescue PreviewCapacity::AtCapacityError => e
    root.update!(full_stack: false, status_message: "Couldn't add the full stack: #{e.message}".truncate(255))
  end

private

  # Dependency previews that only exist in the full stack.
  def extra_previews
    root.tree.drop(1).select { |preview| GovukApps.find(preview.app_name).full_stack_only }
  end
end
