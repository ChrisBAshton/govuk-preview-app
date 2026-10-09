require "rails_helper"

RSpec.describe ConfigOverrides do
  # Runs just the Content Security Policy part against a stand-in for an
  # app's config.
  def run_image_override(config) # rubocop:disable Lint/UnusedMethodArgument
    snippet = described_class.content.lines.drop_while { |line| !line.include?("content_security_policy") }.join
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

    it "doesn't patch any app's own code - e.g. Whitehall's public links come from env vars instead" do
      expect(described_class.content).not_to include("Edition", "prepend", "Whitehall")
    end

    it "forces gds-sso's mock bearer token model, even under GDS_SSO_STRATEGY=real - API calls between previews never reach HostRouter or the internet at all, so this doesn't reopen what that strategy is really for" do
      snippet = described_class.content.lines.drop_while { |line| !line.include?("Warden::OAuth2") }.join
      Warden::OAuth2.config.token_model = GDS::SSO::BearerToken

      eval(snippet) # rubocop:disable Security/Eval

      expect(Warden::OAuth2.config.token_model).to eq(GDS::SSO::MockBearerToken)
    ensure
      Warden::OAuth2.config.token_model = GDS::SSO::MockBearerToken
    end
  end
end
