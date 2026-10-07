require "rails_helper"

RSpec.describe HostRouter do
  let(:app) { ->(_env) { [200, {}, ["app response"]] } }
  let(:router) { described_class.new(app) }

  def env_for(host_with_optional_port, path: "/")
    Rack::MockRequest.env_for("http://#{host_with_optional_port}#{path}")
  end

  it "passes through to the app for the bare host" do
    status, = router.call(env_for(Preview.base_domain))

    expect(status).to eq(200)
  end

  it "passes through to the app for a completely unrelated host" do
    status, = router.call(env_for("example.com"))

    expect(status).to eq(200)
  end

  it "passes through to the app for a suffix-shaped but non-running preview subdomain" do
    status, = router.call(env_for("not-a-real-preview.#{Preview.base_domain}"))

    expect(status).to eq(200)
  end

  it "proxies to the matching running preview's Service, ignoring any port in the Host header" do
    preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
    proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
    allow(Rack::Proxy).to receive(:new).and_return(proxy)
    router = described_class.new(app)

    env = env_for("#{preview.hostname}:12345")
    router.call(env)

    expect(proxy).to have_received(:call).with(
      hash_including("rack.backend" => "http://govuk-preview-app-#{preview.slug}.previews.svc.cluster.local"),
    )
  end

  it "does not proxy a preview that exists but isn't running" do
    create(:preview, app_name: "frontend", branch: "my-branch", status: :waiting_for_image)

    status, = router.call(env_for("frontend-my-branch.#{Preview.base_domain}"))

    expect(status).to eq(200)
  end

  it "does not proxy a running dependency preview - it's internal-only, never hostname-routable" do
    parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
    dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :running)

    status, = router.call(env_for(dependent.hostname))

    expect(status).to eq(200)
  end

  it "proxies a dependency preview whose app is publicly_readable, at its randomised public hostname" do
    parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
    dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :running)
    proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
    allow(Rack::Proxy).to receive(:new).and_return(proxy)
    router = described_class.new(app)

    router.call(env_for(dependent.hostname))

    expect(proxy).to have_received(:call).with(
      hash_including("rack.backend" => "http://#{KubernetesRunner.new(dependent).service_host}"),
    )
  end

  it "does not proxy a publicly_readable dependency preview by its real (internal) slug" do
    parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
    dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :running)

    status, = router.call(env_for("#{dependent.slug}.#{Preview.base_domain}"))

    expect(status).to eq(200)
  end

  describe "sleeping previews" do
    it "serves a self-refreshing waking-up page and queues exactly one wake, however many requests arrive" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :sleeping)

      responses = 3.times.map { router.call(env_for(preview.hostname)) }

      expect(responses.map(&:first)).to eq([503, 503, 503])
      expect(responses.first.last.join).to include("Waking up this preview", 'http-equiv="refresh"')
      expect(PreviewsWakeJob.jobs.map { |job| job["args"].first }).to eq([preview.id])
      expect(preview.reload.status).to eq("waking")
    end

    it "counts visiting a sleeping preview as an interaction" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :sleeping, last_interacted_at: 2.days.ago)

      router.call(env_for(preview.hostname))

      expect(preview.reload.last_interacted_at).to be_within(1.minute).of(Time.current)
    end

    it "wakes the whole stack when a sleeping dependency's public hostname is visited" do
      parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :sleeping)
      dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :sleeping)

      status, = router.call(env_for(dependent.hostname))

      expect(status).to eq(503)
      expect(PreviewsWakeJob.jobs.map { |job| job["args"].first }).to eq([parent.id])
    end

    it "shows why a preview couldn't be woken" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :waking, status_message: "Couldn't wake up: At capacity")

      _, _, body = router.call(env_for(preview.hostname))

      expect(body.join).to include("Couldn&#39;t wake up: At capacity")
    end
  end

  it "records when a running preview's stack was last used" do
    preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
    allow(Rack::Proxy).to receive(:new).and_return(instance_double(Rack::Proxy, call: [200, {}, []]))

    described_class.new(app).call(env_for(preview.hostname))

    expect(preview.reload.last_interacted_at).to be_within(1.minute).of(Time.current)
  end
end
