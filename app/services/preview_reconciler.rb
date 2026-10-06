# Notices when a preview's own infrastructure has disappeared out from
# under it - e.g. someone deleted its objects from the previews namespace,
# or (locally) the kind cluster was recreated - and marks it failed rather
# than leaving a `running` row that HostRouter keeps trying (and failing)
# to proxy to forever. A preview whose pod merely died or was rescheduled
# doesn't count: its Deployment/StatefulSet recreates it by itself. Run at
# boot (see the Preview App manifests' container commands), not
# per-request or on a schedule.
class PreviewReconciler
  def self.run!
    unless KubernetesRunner.api_reachable?
      Rails.logger.warn("PreviewReconciler: Kubernetes API unreachable, skipping")
      return
    end

    Preview.where(status: %i[running sleeping]).find_each do |preview|
      missing = missing_infrastructure_for(preview)
      next if missing.blank?

      preview.update!(
        status: :failed,
        status_message: "Missing from the #{KubernetesApi.namespace} namespace: " \
          "#{missing}. Recreate this preview.",
      )
    end
  end

  # Checks each preview's own objects independently, regardless of any
  # parent/dependent relationship - when a whole stack disappears, every
  # affected preview is independently found missing, so cascading
  # parent<->dependent failures isn't needed.
  def self.missing_infrastructure_for(preview)
    reasons = []
    reasons << "app deployment" unless KubernetesRunner.new(preview).exists?

    app = GovukApps.find(preview.app_name)
    reasons << "database" if app.database && !KubernetesDatabaseRunner.new(preview, app.database).exists?

    reasons.join(", ")
  end
end
