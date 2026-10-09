require "rails_helper"

RSpec.describe HostRouter do
  let(:app) { ->(_env) { [200, {}, ["app response"]] } }
  let(:router) { described_class.new(app) }

  def env_for(host_with_optional_port, path: "/", authenticated: true)
    env = Rack::MockRequest.env_for("http://#{host_with_optional_port}#{path}")
    if authenticated
      token = PreviewSignon.issue_preview_access_token(create(:user))
      env["HTTP_COOKIE"] = "_govuk_preview_access=#{token}"
    end
    env
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

  describe "requiring a real Preview App sign-in" do
    it "redirects to OauthController#continue instead of proxying, preserving the original URL" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
      allow(Rack::Proxy).to receive(:new).and_return(proxy)

      status, headers, = described_class.new(app).call(env_for(preview.hostname, path: "/some/page", authenticated: false))

      expect(status).to eq(302)
      redirect_uri = CGI.escape("#{Preview.scheme}://#{preview.hostname}/some/page")
      expect(headers["location"]).to eq("#{Preview.scheme}://#{Preview.admin_hostname}/oauth/continue?redirect_uri=#{redirect_uri}")
      expect(proxy).not_to have_received(:call)
    end

    it "accepts a valid preview_auth token: sets its own cookie and redirects to the same URL with it stripped" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      user = create(:user)
      token = PreviewSignon.issue_preview_access_token(user)
      proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
      allow(Rack::Proxy).to receive(:new).and_return(proxy)

      env = env_for(preview.hostname, path: "/some/page?preview_auth=#{CGI.escape(token)}&other=1", authenticated: false)
      status, headers, = described_class.new(app).call(env)

      expect(status).to eq(302)
      expect(headers["location"]).to eq("#{Preview.scheme}://#{preview.hostname}/some/page?other=1")
      expect(headers["set-cookie"]).to include("domain=.#{Preview.base_domain}", "httponly")
      cookie_value = CGI.unescape(headers["set-cookie"][/_govuk_preview_access=([^;]+)/, 1])
      expect(cookie_value).to eq(token)
      expect(proxy).not_to have_received(:call)
    end

    it "rejects an invalid or expired preview_auth token, falling back to a login redirect" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)

      env = env_for(preview.hostname, path: "/?preview_auth=not-a-real-token", authenticated: false)
      status, headers, = described_class.new(app).call(env)

      expect(status).to eq(302)
      expect(headers["location"]).to start_with("#{Preview.scheme}://#{Preview.admin_hostname}/oauth/continue")
    end

    it "proxies when the preview_auth cookie from an earlier visit is still valid" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      user = create(:user)
      token = PreviewSignon.issue_preview_access_token(user)
      proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
      allow(Rack::Proxy).to receive(:new).and_return(proxy)

      env = env_for(preview.hostname, authenticated: false)
      env["HTTP_COOKIE"] = "_govuk_preview_access=#{token}"
      described_class.new(app).call(env)

      expect(proxy).to have_received(:call)
    end
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

  describe "a publicly_readable dependency with public_paths" do
    let(:parent) { create(:preview, app_name: "whitehall", branch: "my-branch", status: :running) }
    let(:dependent) { create(:preview, app_name: "asset-manager", branch: "main", parent: parent, status: :running) }
    let(:proxy) { instance_double(Rack::Proxy, call: [200, {}, %w[proxied]]) }

    before { allow(Rack::Proxy).to receive(:new).and_return(proxy) }

    it "proxies reading those paths" do
      described_class.new(app).call(env_for(dependent.hostname, path: "/media/abc/image.jpg"))

      expect(proxy).to have_received(:call)
    end

    it "refuses any other path, or any request that would change something" do
      router = described_class.new(app)

      get_status, = router.call(env_for(dependent.hostname, path: "/assets/abc"))
      post_status, = router.call(Rack::MockRequest.env_for("http://#{dependent.hostname}/media/abc/image.jpg", method: "POST"))

      expect([get_status, post_status]).to eq([404, 404])
      expect(proxy).not_to have_received(:call)
    end
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
