require "rails_helper"

RSpec.describe "Previews" do
  let(:user) { create(:user) }

  # Each row's action links/buttons, without the visually hidden text that
  # says which preview each is for.
  def preview_actions_in(row)
    row.all(".app-actions a, .app-actions button").map { |action| action.text.sub(/ [\w-]+ \([^)]*\)\z/, "") }
  end

  before { login_as(user) }

  describe "GET /previews" do
    it "succeeds and lists existing previews" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      get previews_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("frontend")
      expect(response.body).to include(preview.branch)
    end

    it "shows the Dashboard/Switch app navigation" do
      get previews_path

      expect(response.body).to include(">Dashboard<")
      expect(response.body).to include(">Switch app<")
    end

    it "links a publicly_readable dependency at its own public hostname, rather than showing it as internal-only" do
      parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
      dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :running)

      get previews_path

      expect(response.body).to include(dependent.hostname)
      expect(response.body).not_to include("Internal dependency")
    end

    it "shows an unroutable dependency as an internal dependency, with no link" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :running)

      get previews_path

      expect(response.body).to include("Internal dependency")
    end

    it "lists previews by their newest activity - whichever is more recent of being created and being visited" do
      created_just_now = create(:preview, app_name: "frontend", branch: "created-just-now", created_at: 1.minute.ago)
      visited_recently = create(:preview, app_name: "frontend", branch: "visited-recently", created_at: 3.days.ago, last_interacted_at: 5.minutes.ago)
      created_yesterday = create(:preview, app_name: "frontend", branch: "created-yesterday", created_at: 1.day.ago)
      visited_long_ago = create(:preview, app_name: "frontend", branch: "visited-long-ago", created_at: 5.days.ago, last_interacted_at: 2.days.ago)

      get previews_path

      branches = Capybara::Node::Simple.new(response.body).all("table tbody tr").map { |row| row.all("td")[1].text }
      expect(branches).to eq([created_just_now, visited_recently, created_yesterday, visited_long_ago].map(&:branch))
    end

    it "shows when each preview was created, and when its stack was last visited" do
      create(:preview, app_name: "frontend", branch: "visited", created_at: 2.hours.ago, last_interacted_at: 5.minutes.ago)
      create(:preview, app_name: "frontend", branch: "unvisited")

      get previews_path

      cells = Capybara::Node::Simple.new(response.body).all("table tbody tr").to_h { |row| [row.all("td")[1].text, row.all("td")[4..5].map(&:text)] }
      expect(cells).to eq("visited" => ["about 2 hours ago", "5 minutes ago"], "unvisited" => ["less than a minute ago", "Never"])
    end

    it "lists every dependency beneath the app its stack belongs to, however deep the chain" do
      # Created first, so it's the *older* top-level preview - the
      # controller orders top-level previews newest-first, so this must
      # still end up listed after the whole whitehall chain below.
      other_top_level = create(:preview, app_name: "frontend", branch: "another-branch", status: :running)
      whitehall = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      publishing_api = create(:preview, app_name: "publishing-api", branch: "main", parent: whitehall, status: :running)
      content_store = create(:preview, app_name: "content-store", branch: "main", parent: publishing_api, status: :running)

      get previews_path

      row_texts = Capybara::Node::Simple.new(response.body).all("table tbody tr").map(&:text)
      positions = [whitehall, publishing_api, content_store, other_top_level].index_with do |preview|
        row_texts.index { |text| text.include?(preview.app_name) }
      end

      expect(positions[whitehall]).to be < positions[publishing_api]
      expect(positions[publishing_api]).to be < positions[content_store]
      expect(positions[content_store]).to be < positions[other_top_level]
    end
  end

  describe "GET /previews/new" do
    it "succeeds" do
      get new_preview_path

      expect(response).to have_http_status(:ok)
    end

    it "offers the applications as radio buttons, revealing a full stack box only for apps that have one" do
      get new_preview_path

      page = Capybara::Node::Simple.new(response.body)
      expect(page.all("input[type=radio][name='preview[app_name]']").map(&:value)).to eq(GovukApps.app_names.sort)
      expect(page.all("input[type=checkbox]").map { |box| box[:name] }).to contain_exactly(
        "preview[full_stack_for][whitehall]", "preview[full_stack_for][publishing-api]"
      )
      expect(page.find("#preview_full_stack_whitehall").text).to include("content-store, draft-content-store, frontend, and draft-frontend")
      expect(page.find("#preview_full_stack_publishing_api").text).not_to include("frontend")
    end

    it "only mentions local images when they're enabled" do
      get new_preview_path
      expect(response.body).not_to include("bin/preview-build")

      enable_local_images
      get new_preview_path
      expect(response.body).to include("bin/preview-build")
    end
  end

  describe "POST /previews" do
    it "creates a preview and queues the create job" do
      expect {
        post previews_path, params: { preview: { app_name: "frontend", branch: "my-branch" } }
      }.to change(Preview, :count).by(1).and change(PreviewsCreateJob.jobs, :size).by(1)

      expect(response).to redirect_to(previews_path)
      expect(Preview.last).to have_attributes(app_name: "frontend", branch: "my-branch", status: "queued")
    end

    it "re-renders the form with errors for an unknown app" do
      expect {
        post previews_path, params: { preview: { app_name: "not-a-real-app", branch: "my-branch" } }
      }.not_to change(Preview, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /previews/:id/sleep, /wake and /retry" do
    it "queues putting a running preview to sleep" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)

      expect { post sleep_preview_path(preview) }.to change(PreviewsSleepJob.jobs, :size).by(1)
      expect(response).to redirect_to(previews_path)
    end

    it "queues waking a sleeping preview" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :sleeping)

      expect { post wake_preview_path(preview) }.to change(PreviewsWakeJob.jobs, :size).by(1)
      expect(preview.reload.status).to eq("waking")
    end

    it "retries a failed preview's build from where it stopped" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :failed, status_message: "boom")

      expect { post retry_preview_path(preview) }.to change(PreviewsCreateJob.jobs, :size).by(1)
      expect(preview.reload).to have_attributes(status: "queued", status_message: nil)
    end

    it "queues adding or removing the full stack for a running preview" do
      preview = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)

      post resize_preview_path(preview, full_stack: true)

      expect(PreviewsResizeJob.jobs.last["args"].first(2)).to eq([preview.id, true])
    end

    it "creates a core stack unless the chosen app's full stack box is ticked" do
      post previews_path, params: { preview: { app_name: "whitehall", branch: "core-branch" } }
      post previews_path, params: { preview: { app_name: "whitehall", branch: "full-branch", full_stack_for: { "whitehall" => "true" } } }
      # Ticked under Whitehall, then Publishing API chosen instead - the
      # (now hidden) Whitehall box doesn't count.
      post previews_path, params: { preview: { app_name: "publishing-api", branch: "switched", full_stack_for: { "whitehall" => "true" } } }

      expect(Preview.find_by(branch: "core-branch").full_stack).to be(false)
      expect(Preview.find_by(branch: "full-branch").full_stack).to be(true)
      expect(Preview.find_by(branch: "switched").full_stack).to be(false)
    end

    it "offers adding or removing the full stack only for running apps that have one" do
      create(:preview, app_name: "whitehall", branch: "core-one", status: :running)
      create(:preview, app_name: "whitehall", branch: "full-one", status: :running, full_stack: true)
      create(:preview, app_name: "frontend", branch: "no-extras", status: :running)

      get previews_path

      rows = Capybara::Node::Simple.new(response.body).all("table tbody tr").to_h { |row| [row.all("td")[1].text, preview_actions_in(row)] }
      expect(rows).to eq(
        "core-one" => ["Sleep", "Add full stack", "Delete"],
        "full-one" => ["Sleep", "Remove full stack", "Delete"],
        "no-extras" => %w[Sleep Delete],
      )
    end

    it "offers only the buttons that apply to each preview" do
      create(:preview, app_name: "frontend", branch: "running-one", status: :running)
      create(:preview, app_name: "frontend", branch: "sleeping-one", status: :sleeping)
      create(:preview, app_name: "frontend", branch: "failed-one", status: :failed)

      get previews_path

      rows = Capybara::Node::Simple.new(response.body).all("table tbody tr").to_h { |row| [row.all("td")[1].text, preview_actions_in(row)] }
      expect(rows).to eq(
        "running-one" => %w[Sleep Delete],
        "sleeping-one" => %w[Wake Delete],
        "failed-one" => %w[Retry Delete],
      )
    end
  end

  describe "recording interactions" do
    it "counts creating a preview, and each action on one, as an interaction" do
      post previews_path, params: { preview: { app_name: "frontend", branch: "new-branch" } }
      expect(Preview.find_by(branch: "new-branch").last_interacted_at).to be_within(1.minute).of(Time.current)

      { "running" => :sleep_preview_path, "sleeping" => :wake_preview_path, "failed" => :retry_preview_path }.each do |status, path|
        preview = create(:preview, app_name: "whitehall", branch: "#{status}-branch", status:, last_interacted_at: 3.days.ago)

        post send(path, preview)

        expect(preview.reload.last_interacted_at).to be_within(1.minute).of(Time.current)
      end

      preview = create(:preview, app_name: "whitehall", branch: "resized", status: :running, last_interacted_at: 3.days.ago)
      post resize_preview_path(preview, full_stack: true)
      expect(preview.reload.last_interacted_at).to be_within(1.minute).of(Time.current)
    end

    it "puts a retried preview back at the top, even though it was created long before the others" do
      old_failed = create(:preview, app_name: "frontend", branch: "old-failed", status: :failed, created_at: 2.days.ago)
      create(:preview, app_name: "frontend", branch: "newer", created_at: 1.hour.ago, last_interacted_at: 1.hour.ago)

      post retry_preview_path(old_failed)
      get previews_path

      first_row = Capybara::Node::Simple.new(response.body).first("table tbody tr")
      expect(first_row.all("td")[1].text).to eq("old-failed")
    end
  end

  describe "GET /previews/:id/confirm_destroy" do
    it "asks before deleting, listing what will go with it" do
      preview = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      create(:preview, app_name: "publishing-api", branch: "main", parent: preview, status: :running)

      get confirm_destroy_preview_path(preview)

      page = Capybara::Node::Simple.new(response.body)
      expect(page).to have_css("h1", text: "Delete preview of whitehall (my-branch)?")
      expect(page).to have_css("li", text: "publishing-api (main)")
      expect(page).to have_css("form[action='#{preview_path(preview)}'] input[name='_method'][value='delete']", visible: :all)
      expect(page).to have_button("Delete preview")
    end
  end

  describe "the previews page's row actions" do
    it "are links separated by pipes, with Delete going to a confirmation page and saying which preview each is for" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)

      get previews_path

      actions = Capybara::Node::Simple.new(response.body).find(".app-actions")
      expect(actions).to have_css("button.govuk-link", text: "Sleep frontend (my-branch)")
      expect(actions).to have_css("a.govuk-link.gem-link--destructive[href='#{confirm_destroy_preview_path(preview)}']", text: "Delete frontend (my-branch)")
      expect(actions).to have_css(".app-actions__separator[aria-hidden='true']", text: "|")
    end
  end

  describe "DELETE /previews/:id" do
    it "marks the preview as stopping and queues the destroy job" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)

      expect {
        delete preview_path(preview)
      }.to change(PreviewsDestroyJob.jobs, :size).by(1)

      expect(response).to redirect_to(previews_path)
      expect(preview.reload.status).to eq("stopping")
    end

    it "still deletes a preview whose app_name is no longer in the manifest (e.g. a renamed/removed entry)" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :failed)
      preview.update_column(:app_name, "no-longer-in-the-manifest")

      expect {
        delete preview_path(preview)
      }.to change(PreviewsDestroyJob.jobs, :size).by(1)

      expect(response).to redirect_to(previews_path)
      expect(preview.reload.status).to eq("stopping")
    end
  end
end
