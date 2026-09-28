namespace :previews do
  desc "Mark previews as failed if their underlying containers no longer exist"
  task reconcile: :environment do
    PreviewReconciler.run!
  end
end
