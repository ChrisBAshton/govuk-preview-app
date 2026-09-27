module GovukApps
  Database = Struct.new(:adapter, :image, keyword_init: true)
  Definition = Struct.new(:name, :repo_url, :port_env_var, :env, :dependencies, :database, keyword_init: true)

  def self.all
    @all ||= YAML.load_file(Rails.root.join("config/govuk_apps.yml")).map do |name, attrs|
      database = attrs["database"] && Database.new(
        adapter: attrs["database"].fetch("adapter"),
        image: attrs["database"].fetch("image"),
      )

      Definition.new(
        name: name,
        repo_url: attrs.fetch("repo_url"),
        port_env_var: attrs.fetch("port_env_var"),
        env: attrs.fetch("env", {}),
        dependencies: attrs.fetch("dependencies", []),
        database: database,
      )
    end
  end

  def self.app_names
    all.map(&:name)
  end

  def self.find(name)
    all.find { |app| app.name == name }
  end
end
