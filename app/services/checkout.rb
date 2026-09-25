require "open3"

class Checkout
  class GitError < StandardError; end

  def self.root
    Pathname.new(ENV.fetch("APP_PREVIEW_CHECKOUT_ROOT", Rails.root.join("tmp/checkouts")))
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

    if path.exist?
      run!("git", "-C", path.to_s, "fetch", "origin", preview.branch)
      run!("git", "-C", path.to_s, "checkout", "-B", preview.branch, "origin/#{preview.branch}")
    else
      run!("git", "clone", "--branch", preview.branch, "--single-branch", repo_url, path.to_s)
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
