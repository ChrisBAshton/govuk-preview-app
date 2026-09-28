require "open3"

class Checkout
  class GitError < StandardError; end

  def self.root
    Pathname.new(ENV.fetch("PREVIEW_APP_CHECKOUT_ROOT", Rails.root.join("tmp/checkouts")))
  end

  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  def path
    self.class.root.join(preview.app_name, preview.slug)
  end

  def checkout!
    FileUtils.mkdir_p(self.class.root.join(preview.app_name))

    repo_url = GovukApps.find(preview.app_name).repo_url

    # Belt and suspenders alongside GovukApps.all's own check: this is the
    # actual dangerous operation (clone, then build+run as root via a
    # Docker daemon Preview App has full access to), so it's worth
    # refusing here too even though repo_url should already be
    # guaranteed trusted by the time it gets this far.
    unless GovukApps.trusted_repo_url?(repo_url)
      raise GitError, "Refusing to clone untrusted repo_url: #{repo_url.inspect}"
    end

    # Shallow: we only ever need the current state of one branch, not its
    # history - meaningfully faster, and less exposed to the kind of
    # mid-transfer network blip a full clone of a large repo hits more often.
    if path.exist?
      run!("git", "-C", path.to_s, "fetch", "--depth", "1", "origin", preview.branch)
      run!("git", "-C", path.to_s, "checkout", "-B", preview.branch, "origin/#{preview.branch}")
    else
      run!("git", "clone", "--branch", preview.branch, "--single-branch", "--depth", "1", repo_url, path.to_s)
    end

    path
  end

  def remove!
    FileUtils.rm_rf(path)
  end

private

  def run!(*command)
    _out, err, status = Open3.capture3(*command)
    raise GitError, err unless status.success?
  end
end
