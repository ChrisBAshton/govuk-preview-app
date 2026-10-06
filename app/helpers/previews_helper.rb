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

  # Revealed beneath an app's radio button on the new-preview form, for apps
  # whose full stack runs more than their core one. Each app gets its own
  # field (preview[full_stack_for][<app>]), so a box ticked under one app
  # and then hidden by choosing another is never mistaken for the new
  # choice - see PreviewsController#preview_params.
  def full_stack_checkbox(app_name, checked:)
    extras = GovukApps.full_stack_extras(app_name)

    render "govuk_publishing_components/components/checkboxes", {
      id: "preview_full_stack_#{app_name.underscore}",
      name: "preview[full_stack_for][#{app_name}]",
      heading: "Full stack",
      visually_hide_heading: true,
      no_hint_text: true,
      items: [
        {
          label: "Full stack",
          value: "true",
          checked: checked,
          hint: "Also runs #{extras.to_sentence}, so this preview's published and draft pages can be viewed - " \
                "using more memory. Can be added or removed later.",
        },
      ],
    }
  end

  # What the branch field accepts - see ImageResolver.
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
    if preview.running? && preview.status_message.blank? && GovukApps.full_stack_option?(preview.app_name)
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
