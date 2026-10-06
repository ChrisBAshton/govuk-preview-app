# Sidekiq's fake mode (see rails_helper.rb) keeps queued jobs in memory
# across examples unless they're cleared.
RSpec.configure do |config|
  config.before { Sidekiq::Job.clear_all }
end
