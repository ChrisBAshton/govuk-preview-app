require "rails_helper"

RSpec.describe InterruptedJobResumer do
  let(:queue) { [] }
  let(:retries) { [] }
  let(:scheduled) { [] }
  let(:workers) { [] }

  before do
    allow(Sidekiq::Queue).to receive(:new).and_return(queue)
    allow(Sidekiq::RetrySet).to receive(:new).and_return(retries)
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return(scheduled)
    allow(Sidekiq::Workers).to receive(:new).and_return(workers)
  end

  def job(job_class, preview)
    instance_double(Sidekiq::JobRecord, klass: job_class.name, args: [preview.id])
  end

  describe ".run!" do
    it "re-queues the build of a top-level preview left mid-build with no job to finish it" do
      preview = create(:preview, app_name: "whitehall", branch: "my-branch", status: :starting)

      expect { described_class.run! }.to change(PreviewsCreateJob.jobs, :size).by(1)
      expect(PreviewsCreateJob.jobs.last["args"].first).to eq(preview.id)
    end

    it "re-queues the teardown of a preview left mid-teardown" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :stopping)

      expect { described_class.run! }.to change(PreviewsDestroyJob.jobs, :size).by(1)
      expect(PreviewsDestroyJob.jobs.last["args"].first).to eq(preview.id)
    end

    it "re-queues waking a preview left mid-wake" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :waking)

      expect { described_class.run! }.to change(PreviewsWakeJob.jobs, :size).by(1)
      expect(PreviewsWakeJob.jobs.last["args"].first).to eq(preview.id)
    end

    it "re-queues a resize left part-way, with the stack size it was changing to" do
      preview = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running, full_stack: true,
                                 status_message: PreviewResizer::ADDING)

      expect { described_class.run! }.to change(PreviewsResizeJob.jobs, :size).by(1)
      expect(PreviewsResizeJob.jobs.last["args"].first(2)).to eq([preview.id, true])
    end

    it "leaves finished previews, and dependents (built by their parent's job), alone" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :starting)
      create(:preview, app_name: "frontend", branch: "failed-branch", status: :failed)

      expect { described_class.run! }.not_to change(PreviewsCreateJob.jobs, :size)
    end

    it "doesn't queue a second job when Sidekiq still has one, wherever it is" do
      queued = create(:preview, app_name: "frontend", branch: "a", status: :queued)
      retrying = create(:preview, app_name: "frontend", branch: "b", status: :starting)
      in_progress = create(:preview, app_name: "frontend", branch: "c", status: :waiting_for_image)
      queue << job(PreviewsCreateJob, queued)
      retries << job(PreviewsCreateJob, retrying)
      workers << ["process", "thread", instance_double(Sidekiq::Work, job: job(PreviewsCreateJob, in_progress))]

      expect { described_class.run! }.not_to change(PreviewsCreateJob.jobs, :size)
    end
  end
end
