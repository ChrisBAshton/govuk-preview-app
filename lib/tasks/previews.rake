namespace :previews do
  desc "Mark previews as failed if their underlying containers no longer exist"
  task reconcile: :environment do
    PreviewReconciler.run!
  end

  desc "Re-queue the build/teardown of any preview whose job was lost part-way"
  task resume: :environment do
    InterruptedJobResumer.run!
  end
end
