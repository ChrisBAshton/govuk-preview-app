require "rails_helper"

RSpec.describe "Healthchecks" do
  # As Kubernetes' probes do: by pod IP, not signed in.
  before { host! "10.0.0.1" }

  it "reports the app live" do
    get "/healthcheck/live"

    expect(response).to have_http_status(:ok)
  end

  it "reports the app ready when its database and Redis are reachable" do
    get "/healthcheck/ready"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("status" => "ok")
  end
end
