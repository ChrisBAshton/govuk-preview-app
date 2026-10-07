require "sidekiq/api"

# Re-queues the build (or teardown) of any top-level preview whose Sidekiq
# job was lost part-way - e.g. the worker was killed outright (Docker
# Desktop quit, an OOM kill, a node disappearing) rather than shut down
# gracefully, which is the only case where Sidekiq itself puts an
# in-progress job back on the queue. Without this, such a preview stays
# `starting` (or `stopping`) forever, with nothing left to finish it.
#
# Safe because every one of these jobs can be re-run from any point:
# PreviewBuilder reuses whatever dependency previews already exist and
# leaves running ones alone, waking just scales things up (again), and
# PreviewDestroyer ignores objects that are already gone.
#
# Run once, by the worker only, at boot (see kubernetes/local/
# preview-app.yaml) - not by the web pod too, which boots at the same time
# and would race it into queueing every job twice.
class InterruptedJobResumer
  JOBS = {
    PreviewsCreateJob => %w[queued waiting_for_image starting],
    PreviewsWakeJob => %w[waking],
    PreviewsDestroyJob => %w[stopping],
  }.freeze

  def self.run!
    # A resize leaves the preview running, so it's recognised by the
    # message it shows while in progress instead.
    Preview.where(parent_id: nil, status: :running, status_message: [PreviewResizer::ADDING, PreviewResizer::REMOVING]).find_each do |preview|
      next if !preview.app_known? || job_pending?(PreviewsResizeJob, preview)

      PreviewsResizeJob.perform_async(preview.id, preview.full_stack)
    end

    JOBS.each do |job_class, statuses|
      Preview.where(parent_id: nil, status: statuses).find_each do |preview|
        # Nothing to build, wake or resize for an app that's been removed
        # from the manifest - but it can still be deleted.
        next if job_class != PreviewsDestroyJob && !preview.app_known?
        next if job_pending?(job_class, preview)

        Rails.logger.info("InterruptedJobResumer: re-queueing #{job_class} for preview #{preview.slug}")
        job_class.perform_async(preview.id)
      end
    end
  end

  # Whether Sidekiq still has this preview's job anywhere - queued,
  # waiting to retry or scheduled, or being worked on right now (e.g. by a
  # previous worker that's still shutting down gracefully).
  def self.job_pending?(job_class, preview)
    matches = ->(job) { job.klass == job_class.name && job.args.first == preview.id }

    [Sidekiq::Queue.new, Sidekiq::RetrySet.new, Sidekiq::ScheduledSet.new].any? { |jobs| jobs.any?(&matches) } ||
      Sidekiq::Workers.new.any? { |_process, _thread, work| matches.call(work.job) }
  end
end
