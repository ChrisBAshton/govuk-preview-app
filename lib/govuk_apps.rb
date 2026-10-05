module GovukApps
  # We `docker build`/`docker run` whatever a manifest entry's `repo_url`
  # points at, as root, via a Docker daemon Preview App itself has full
  # access to (see Checkout, DockerRunner) - an untrusted repo here isn't
  # just "the wrong code gets previewed", it's arbitrary build/run
  # instructions on the same node. Restricting to a single, known GitHub
  # org is a hard invariant, not just a config convention: enforced once
  # here (so a bad manifest entry stops the app booting at all, loudly,
  # rather than quietly being previewable) and again at the actual clone
  # in Checkout (in case some future code path ever builds a Definition
  # some other way, bypassing this).
  TRUSTED_GITHUB_ORG = "alphagov".freeze

  Database = Struct.new(:adapter, :image, keyword_init: true)
  Definition = Struct.new(
    :name, :repo_url, :port_env_var, :env, :dependencies, :database, :setup_tasks,
    :worker_command, :publicly_readable, :env_aliases, keyword_init: true
  )

  def self.all
    @all ||= YAML.load_file(Rails.root.join("config/govuk_apps.yml")).map do |name, attrs|
      repo_url = attrs.fetch("repo_url")
      unless trusted_repo_url?(repo_url)
        raise "config/govuk_apps.yml declares an untrusted repo_url for #{name.inspect}: #{repo_url.inspect} " \
          "(must be https://github.com/#{TRUSTED_GITHUB_ORG}/...)"
      end

      database = attrs["database"] && Database.new(
        adapter: attrs["database"].fetch("adapter"),
        image: attrs["database"].fetch("image"),
      )

      Definition.new(
        name: name,
        repo_url: repo_url,
        port_env_var: attrs.fetch("port_env_var"),
        env: attrs.fetch("env", {}),
        dependencies: attrs.fetch("dependencies", []),
        database: database,
        setup_tasks: attrs.fetch("setup_tasks", []),
        worker_command: attrs["worker_command"],
        publicly_readable: attrs.fetch("publicly_readable", false),
        env_aliases: attrs.fetch("env_aliases", {}),
      )
    end
  end

  def self.app_names
    all.map(&:name)
  end

  def self.find(name)
    all.find { |app| app.name == name }
  end

  # Parses with URI rather than a string prefix/regex match, so a URL
  # designed to *look* right to a naive check (userinfo tricks like
  # "https://github.com@evil.com/...", lookalike hosts like
  # "github.com.evil.com") doesn't slip through - `URI#host` and `#path`
  # are the actual, unambiguous authority/path components.
  def self.trusted_repo_url?(url)
    uri = URI.parse(url)
    uri.is_a?(URI::HTTPS) && uri.host == "github.com" && uri.path.start_with?("/#{TRUSTED_GITHUB_ORG}/")
  rescue URI::InvalidURIError
    false
  end
end
