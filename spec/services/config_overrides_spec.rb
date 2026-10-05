require "rails_helper"

RSpec.describe ConfigOverrides do
  let(:checkout_path) { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.rm_rf(checkout_path) }

  describe "#write!" do
    it "writes an initializer disabling x_sendfile_header, overriding the database connection, and clearing config.hosts" do
      described_class.new(checkout_path).write!

      content = checkout_path.join("config/initializers/zzz_preview_app_overrides.rb").read

      expect(content).to include("config.action_dispatch.x_sendfile_header = nil")
      expect(content).to include('ActiveRecord::Base.establish_connection(ENV["DATABASE_URL"])')
      expect(content).to include("config.hosts.clear")
    end

    it "creates config/initializers if it doesn't already exist" do
      described_class.new(checkout_path).write!

      expect(checkout_path.join("config/initializers")).to be_a_directory
    end

    it "writes a to_prepare-wrapped Edition#public_url override, for Whitehall's Preview/View on website links" do
      described_class.new(checkout_path).write!

      content = checkout_path.join("config/initializers/zzz_preview_app_overrides.rb").read

      expect(content).to include("Rails.application.config.to_prepare do")
      expect(content).to include("if defined?(Whitehall) && defined?(Edition)")
      expect(content).to include("Edition.prepend(Module.new do")
    end

    describe "the Edition#public_url override itself" do
      # Edition doesn't exist in Preview App's own process - only inside a
      # real Whitehall container - so this stubs a bare stand-in to prove
      # the override's actual *behaviour* (not just its presence in the
      # written file, checked above).
      #
      # `Rails.application.config.to_prepare { ... }` only appends to a
      # plain array (`config.to_prepare_blocks`) - in a real app boot, a
      # one-time `:add_to_prepare_blocks` initializer (in Rails' own
      # `Finisher`) is what actually wires each of those blocks into
      # `app.reloader`, which is what `Rails.application.reloader.prepare!`
      # then triggers. Preview App's own test process already finished
      # booting (and ran that initializer) long before this spec's `load`
      # call appends a new block - nothing re-runs that wiring step for it.
      # So, exactly mirroring what that initializer does for each block,
      # this wires it in manually before triggering it.
      before do
        stub_const("Edition", Class.new do
          def base_path = "/some-path"
          def public_path(_options = {}) = base_path
          def public_url(options = {}) = (options[:draft] ? "https://draft-fallback.example" : "https://live-fallback.example")
        end)

        described_class.new(checkout_path).write!
        load checkout_path.join("config/initializers/zzz_preview_app_overrides.rb").to_s
        Rails.application.config.to_prepare_blocks.each { |block| Rails.application.reloader.to_prepare(&block) }
      end

      context "when Whitehall is defined (i.e. we're actually inside Whitehall)" do
        before do
          stub_const("Whitehall", Module.new)
          Rails.application.reloader.prepare!
        end

        it "uses PLEK_SERVICE_FRONTEND_PUBLIC_URL for the live link when set" do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("PLEK_SERVICE_FRONTEND_PUBLIC_URL").and_return("http://frontend.example")

          expect(Edition.new.public_url).to eq("http://frontend.example/some-path")
        end

        it "uses PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL for the draft link when set" do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL").and_return("http://draft-frontend.example")

          expect(Edition.new.public_url(draft: true)).to eq("http://draft-frontend.example/some-path")
        end

        it "falls back to the original implementation when neither env var is set" do
          expect(Edition.new.public_url).to eq("https://live-fallback.example")
          expect(Edition.new.public_url(draft: true)).to eq("https://draft-fallback.example")
        end
      end

      context "when Whitehall is not defined (e.g. Publishing API, which happens to have its own, unrelated Edition model)" do
        before { Rails.application.reloader.prepare! }

        # The real bug this guards against: `defined?` on a not-yet-loaded,
        # autoloadable constant actually forces it to load (confirmed by
        # direct reproduction against the real app) - so checking
        # `defined?(Edition)` alone, without first confirming we're in
        # Whitehall, would force *any* app's own unrelated Edition class to
        # load during this to_prepare block, which broke Publishing API's
        # own db:create/db:schema:load (its Edition model's SymbolizeJSON
        # concern does schema introspection at class-load time, before the
        # database exists). Guarding on `defined?(Whitehall)` first means
        # `defined?(Edition)` is never even evaluated here.
        it "never touches Edition at all, leaving its original public_url untouched" do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("PLEK_SERVICE_FRONTEND_PUBLIC_URL").and_return("http://frontend.example")

          expect(Edition.new.public_url).to eq("https://live-fallback.example")
        end
      end
    end
  end
end
