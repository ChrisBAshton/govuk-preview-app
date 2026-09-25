module GovukApps
  Definition = Struct.new(:name, :repo_url, :port_env_var, keyword_init: true)

  def self.all
    @all ||= YAML.load_file(Rails.root.join("config/govuk_apps.yml")).map do |name, attrs|
      Definition.new(name: name, repo_url: attrs.fetch("repo_url"), port_env_var: attrs.fetch("port_env_var"))
    end
  end

  def self.app_names
    all.map(&:name)
  end

  def self.find(name)
    all.find { |app| app.name == name }
  end
end
