module PreviewsHelper
  # Each top-level preview followed by every dependency in its stack, as
  # [preview, dependency?] pairs. Dependencies are listed one level deep, in
  # build order, however they're chained underneath (e.g. Content Store is
  # built beneath Publishing API only so Publishing API gets its address -
  # it's there for the preview of Whitehall as a whole).
  def previews_with_dependencies(previews)
    previews.flat_map do |preview|
      [[preview, false], *preview.tree.drop(1).sort_by(&:created_at).map { |dependency| [dependency, true] }]
    end
  end

  # What the branch field accepts - see ImageResolver.
  # Whether this app's full stack differs from its core stack at all - e.g.
  # not for Frontend, which has no dependencies.
  def has_full_stack_extras?(preview)
    GovukApps.dependency_tree(preview.app_name) != GovukApps.dependency_tree(preview.app_name, full_stack: false)
  end

  def preview_action(text, path, modifier, method: :post, **options)
    button_to(text, path, method:, class: "govuk-button #{modifier} govuk-!-margin-bottom-0", form_class: "govuk-!-display-inline-block", **options)
  end

  def branch_hint
    sources = [
      safe_join([tag.code("main"), " - the app's latest release"]),
      "any other branch on GitHub, once the app's \"Build image from PR\" workflow has pushed its image",
    ]
    if ImageResolver.local_images_enabled?
      sources << safe_join([tag.code("local:<tag>"), " - an image built from your own checkout with ", tag.code("bin/preview-build")])
    end

    tag.ul(safe_join(sources.map { |source| tag.li(source) }), class: "govuk-list govuk-list--bullet")
  end

  # Buttons for a top-level preview (dependencies go wherever it goes).
  def preview_actions(preview)
    buttons = []
    buttons << preview_action("Sleep", sleep_preview_path(preview), "govuk-button--secondary") if preview.running?
    if preview.running? && preview.status_message.blank? && has_full_stack_extras?(preview)
      label = preview.full_stack? ? "Remove full stack" : "Add full stack"
      buttons << preview_action(label, resize_preview_path(preview, full_stack: !preview.full_stack?), "govuk-button--secondary")
    end
    buttons << preview_action("Wake", wake_preview_path(preview), "govuk-button--secondary") if preview.sleeping?
    buttons << preview_action("Retry", retry_preview_path(preview), "govuk-button--secondary") if preview.failed?
    buttons << preview_action("Delete", preview_path(preview), "govuk-button--warning", method: :delete, data: { confirm: "Are you sure?" })

    tag.div(safe_join(buttons), class: "govuk-button-group govuk-!-margin-bottom-0")
  end

  # "5 minutes ago", with the exact time on hover.
  def preview_time(time, blank: "")
    return blank if time.blank?

    tag.time("#{time_ago_in_words(time)} ago", datetime: time.iso8601, title: time.to_fs(:long))
  end

  def preview_app_name_cell(preview, dependency)
    return preview.app_name unless dependency

    # The class also shades the dependency's whole row - see application.scss.
    tag.span("↳ #{preview.app_name}", class: "app-dependency-name")
  end
end
