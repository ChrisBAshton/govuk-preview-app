# Notices when a preview's own infrastructure has disappeared out from
# under it - e.g. the node backing Preview App's Docker-outside-of-Docker
# socket was replaced, or a container was removed by something else - and
# marks it failed rather than leaving a `running` row that HostRouter keeps
# trying (and failing) to proxy to forever. Run at boot (see
# docker-compose.yml's migrate/app/worker service commands), not
# per-request or on a schedule - Docker daemon calls aren't free, and a
# preview isn't going anywhere between checks.
class PreviewReconciler
  def self.run!
    unless DockerRunner.daemon_reachable?
      Rails.logger.warn("PreviewReconciler: Docker daemon unreachable, skipping")
      return
    end

    Preview.running.find_each do |preview|
      missing = missing_infrastructure_for(preview)
      next if missing.blank?

      preview.update!(
        status: :failed,
        status_message: "Container no longer exists (#{missing}) - the node " \
          "or Docker daemon this preview's containers were running on may " \
          "have recycled. Recreate this preview.",
      )
    end
  end

  # Checks each preview's own containers independently, regardless of any
  # parent/dependent relationship - in the realistic failure mode (a node
  # disappears), every affected preview's own containers are independently
  # found missing, so cascading parent<->dependent failures isn't needed.
  def self.missing_infrastructure_for(preview)
    reasons = []
    reasons << "app container" unless DockerRunner.new(preview).exists?

    app = GovukApps.find(preview.app_name)
    reasons << "database container" if app.database && !DatabaseRunner.new(preview, app.database).exists?

    reasons.join(", ")
  end
end
