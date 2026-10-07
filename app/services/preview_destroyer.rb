# Deletes a preview's Kubernetes objects (Deployments, Services, Jobs,
# ConfigMap, and its database's StatefulSet and volume, if any), then
# destroys its record - recursing into its dependents *first*, since each
# owns its own objects that a plain AR `dependent: :destroy` can't clean up
# (see Preview#dependents).
class PreviewDestroyer
  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  def destroy!
    preview.dependents.each { |dependent| self.class.new(dependent).destroy! }

    KubernetesRunner.new(preview).stop!

    # For an app since removed from the manifest there's no telling whether
    # it had a database - so delete one if it's there (deleting what isn't
    # is harmless), rather than leaving a StatefulSet and volume behind.
    database = GovukApps.find(preview.app_name)&.database
    KubernetesDatabaseRunner.new(preview, database).stop! if database || !preview.app_known?
    StackRedis.new(preview).stop! if preview.parent_id.nil?

    preview.destroy!
  end
end
