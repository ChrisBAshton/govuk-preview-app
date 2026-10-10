require "rails_helper"

RSpec.describe ConfigOverrides do
  # Runs just the Content Security Policy part against a stand-in for an
  # app's config.
  def run_image_override(config) # rubocop:disable Lint/UnusedMethodArgument
    snippet = described_class.content.lines
      .drop_while { |line| !line.include?("content_security_policy") }
      .take_while { |line| !line.include?("Warden::OAuth2") }
      .join
    eval(snippet.gsub("Rails.application.config", "config")) # rubocop:disable Security/Eval
  end

  describe ".content" do
    it "is valid Ruby" do
      expect { RubyVM::InstructionSequence.compile(described_class.content) }.not_to raise_error
    end

    it "reconnects from DATABASE_URL on top of the app's own config, rather than instead of it" do
      expect(described_class.content).to include("configs_for(env_name: Rails.env)", "merge(url: ENV[\"DATABASE_URL\"])")
    end

    it "lets apps with a Content Security Policy show images from any preview, e.g. its stack's Asset Manager" do
      policy = ActionDispatch::ContentSecurityPolicy.new { |p| p.img_src :self, "*.dev.gov.uk" }
      config = Struct.new(:content_security_policy).new(policy)

      run_image_override(config)

      expect(policy.directives["img-src"]).to eq(["'self'", "*.dev.gov.uk", "http://*.govuk-preview-app.dev.gov.uk"])
    end

    it "leaves apps with no Content Security Policy without one" do
      expect { run_image_override(Struct.new(:content_security_policy).new(nil)) }.not_to raise_error
    end

    it "doesn't patch any other app's own code - e.g. Whitehall's public links come from env vars instead" do
      expect(described_class.content).not_to include("Edition", "prepend", "Whitehall")
    end

    it "skips Asset Manager's own Signon gate for reading an asset, but leaves everything else up to it" do
      stand_in = Class.new do
        def authorized_for_asset?(_asset) = false

        def redirect_to_draft_assets_host_for?(_asset) = true
      end
      stub_const("MediaController", stand_in)
      # The patch only registers a to_prepare callback (MediaController
      # isn't autoloaded yet when this file actually runs) - run it as
      # soon as it's registered, rather than relying on the reloader's
      # own timing (already long past its one real boot-time run here).
      allow(Rails.application.config).to receive(:to_prepare).and_yield
      snippet = described_class.content.lines.drop_while { |line| !line.include?("MediaController") }.join

      eval(snippet) # rubocop:disable Security/Eval

      instance = stand_in.new
      expect(instance.send(:authorized_for_asset?, nil)).to be(true)
      expect(instance.send(:redirect_to_draft_assets_host_for?, nil)).to be(false)
    end

    it "recognises its own pod's internal address as internal - Plek.find(\"asset-manager\") from inside its own pod just falls back to the real asset-manager.www.gov.uk" do
      stand_in = Class.new { attr_accessor :request }
      stub_const("MediaController", stand_in)
      allow(Rails.application.config).to receive(:to_prepare).and_yield
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PREVIEW_APP_INTERNAL_URL")
                                    .and_return("http://govuk-preview-app-asset-manager-main-for-whitehall-main")
      snippet = described_class.content.lines.drop_while { |line| !line.include?("MediaController") }.join

      eval(snippet) # rubocop:disable Security/Eval
      instance = stand_in.new

      instance.request = double(host: "govuk-preview-app-asset-manager-main-for-whitehall-main")
      expect(instance.send(:requested_from_internal_host?)).to be(true)

      instance.request = double(host: "asset-manager-2nsyuxa.govuk-preview-app.dev.gov.uk")
      expect(instance.send(:requested_from_internal_host?)).to be(false)
    end

    it "rebases a fake-S3 redirect to its own internal address for a request from another preview's own pod, which can never reach its public hostname" do
      stand_in = Class.new do
        attr_accessor :request, :response, :headers, :redirected_to

        def initialize
          @headers = {}
        end

        def redirect_to(url) = @redirected_to = url
      end
      stub_const("MediaController", stand_in)
      stub_const("AssetManager", double(s3: double(fake?: true), content_disposition: double(header_for: "inline")))
      stub_const(
        "Services",
        double(cloud_storage: double(
          presigned_url_for: "http://asset-manager-2nsyuxa.govuk-preview-app.dev.gov.uk:8080/fake-s3/foo/bar.png",
        )),
      )
      allow(Rails.application.config).to receive(:to_prepare).and_yield
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PREVIEW_APP_INTERNAL_URL")
                                    .and_return("http://govuk-preview-app-asset-manager-main-for-whitehall-main")
      snippet = described_class.content.lines.drop_while { |line| !line.include?("MediaController") }.join

      eval(snippet) # rubocop:disable Security/Eval
      instance = stand_in.new
      instance.request = double(fresh?: false, request_method: "GET", host: "govuk-preview-app-asset-manager-main-for-whitehall-main")
      asset = double(etag: "abc", last_modified: double(httpdate: "Fri, 01 Jan 2027 00:00:00 GMT"))

      instance.send(:proxy_to_s3_via_nginx, asset)

      expect(instance.redirected_to).to eq("http://govuk-preview-app-asset-manager-main-for-whitehall-main/fake-s3/foo/bar.png")
    end

    it "forces gds-sso's mock bearer token model, even under GDS_SSO_STRATEGY=real - API calls between previews never reach HostRouter or the internet at all, so this doesn't reopen what that strategy is really for" do
      snippet = described_class.content.lines.drop_while { |line| !line.include?("Warden::OAuth2") }.join
      Warden::OAuth2.config.token_model = GDS::SSO::BearerToken

      eval(snippet) # rubocop:disable Security/Eval

      expect(Warden::OAuth2.config.token_model).to eq(GDS::SSO::MockBearerToken)
    ensure
      Warden::OAuth2.config.token_model = GDS::SSO::MockBearerToken
    end

    it "grants the mock dummy API user a permission to manage any asset, not just ones it's literally the same row as" do
      snippet = described_class.content.lines.drop_while { |line| !line.include?("GDS::SSO::Config)") }.join
      original = GDS::SSO::Config.additional_mock_permissions_required

      eval(snippet) # rubocop:disable Security/Eval

      expect(GDS::SSO::Config.additional_mock_permissions_required).to include("Manage all Assets")
    ensure
      GDS::SSO::Config.additional_mock_permissions_required = original
    end
  end
end
