module GovukApps
  # We run whatever image a manifest entry's `repo_url` resolves to (see
  # ImageResolver) - an untrusted repo here isn't just "the wrong code gets
  # previewed", it's arbitrary code running in the cluster. Restricting to
  # a single, known GitHub org is a hard invariant, not just a config
  # convention: enforced here, so a bad manifest entry stops the app booting
  # at all, loudly, rather than quietly being previewable. (ImageResolver
  # also only ever pulls from ghcr.io/alphagov/govuk.)
  TRUSTED_GITHUB_ORG = "alphagov".freeze

  Database = Struct.new(:adapter, :image, keyword_init: true)
  Definition = Struct.new(
    :name, :repo_url, :port_env_var, :env, :dependencies, :database, :setup_tasks,
    :worker_command, :publicly_readable, :env_aliases, :full_stack_dependencies, :resync_tasks, keyword_init: true
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
        full_stack_dependencies: attrs.fetch("full_stack_dependencies", []),
        resync_tasks: attrs.fetch("resync_tasks", []),
      )
    end
  end

  def self.app_names
    all.map(&:name)
  end

  def self.find(name)
    all.find { |app| app.name == name }
  end

  # Every app a preview of `name` starts a dependency preview of, at any
  # depth, in build order - e.g. whitehall's full stack -> publishing-api,
  # content-store, draft-content-store, frontend, draft-frontend; its core
  # stack -> just publishing-api. Used to work out how much room a whole
  # preview stack needs (PreviewCapacity).
  def self.dependency_tree(name, full_stack: true)
    app = find(name)
    return [] unless app

    direct = full_stack ? app.dependencies + app.full_stack_dependencies : app.dependencies
    direct.flat_map { |dep| [dep, *dependency_tree(dep, full_stack:)] }
  end

  # Whether a preview of `name` has a full stack worth offering - i.e. one
  # that runs anything its core stack doesn't.
  def self.full_stack_option?(name)
    full_stack_extras(name).any?
  end

  # What a preview of `name`'s full stack runs on top of its core stack.
  def self.full_stack_extras(name)
    dependency_tree(name) - dependency_tree(name, full_stack: false)
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
