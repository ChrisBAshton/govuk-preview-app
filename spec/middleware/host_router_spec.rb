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

  it "proxies to the matching running preview's container, ignoring any port in the Host header" do
    preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running, port: 20_123)
    proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
    allow(Rack::Proxy).to receive(:new).and_return(proxy)
    router = described_class.new(app)

    env = env_for("#{preview.hostname}:12345")
    router.call(env)

    expect(proxy).to have_received(:call).with(
      hash_including("rack.backend" => "http://govuk-preview-app-#{preview.slug}:20123"),
    )
  end

  it "does not proxy a preview that exists but isn't running" do
    create(:preview, app_name: "frontend", branch: "my-branch", status: :building)

    status, = router.call(env_for("frontend-my-branch.#{Preview.base_domain}"))

    expect(status).to eq(200)
  end

  it "does not proxy a running dependency preview - it's internal-only, never hostname-routable" do
    parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running, port: 20_000)
    dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :running, port: 20_001)

    status, = router.call(env_for(dependent.hostname))

    expect(status).to eq(200)
  end

  it "proxies a dependency preview whose app is publicly_readable, at its randomised public hostname" do
    parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running, port: 20_000)
    dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :running, port: 20_001)
    proxy = instance_double(Rack::Proxy, call: [200, {}, %w[proxied]])
    allow(Rack::Proxy).to receive(:new).and_return(proxy)
    router = described_class.new(app)

    router.call(env_for(dependent.hostname))

    expect(proxy).to have_received(:call).with(
      hash_including("rack.backend" => "http://#{DockerRunner.new(dependent).container_name}:20001"),
    )
  end

  it "does not proxy a publicly_readable dependency preview by its real (internal) slug" do
    parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running, port: 20_000)
    dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :running, port: 20_001)

    status, = router.call(env_for("#{dependent.slug}.#{Preview.base_domain}"))

    expect(status).to eq(200)
  end
end
