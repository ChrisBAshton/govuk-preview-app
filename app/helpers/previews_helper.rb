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

  # A top-level preview's actions (its dependencies go wherever it goes),
  # as links separated by pipes - like Whitehall's admin tables. Each says
  # which preview it's for to screen readers, as Whitehall's do.
  def preview_actions(preview)
    actions = []
    actions << preview_post_link("Sleep", sleep_preview_path(preview), preview) if preview.running?
    if preview.running? && preview.status_message.blank? && GovukApps.full_stack_option?(preview.app_name)
      label = preview.full_stack? ? "Remove full stack" : "Add full stack"
      actions << preview_post_link(label, resize_preview_path(preview, full_stack: !preview.full_stack?), preview)
    end
    actions << preview_post_link("Wake", wake_preview_path(preview), preview) if preview.sleeping?
    actions << preview_post_link("Retry", retry_preview_path(preview), preview) if preview.failed?
    # Deleting asks first, on a page of its own - see #confirm_destroy.
    actions << link_to(
      safe_join(["Delete", preview_action_context(preview)]),
      confirm_destroy_preview_path(preview),
      class: "govuk-link gem-link--destructive",
    )

    tag.div(safe_join(actions, tag.span("|", class: "app-actions__separator", "aria-hidden": "true")), class: "app-actions")
  end

  # These actions change things, so they POST - from a form whose button
  # is styled exactly like a link (see application.scss).
  def preview_post_link(text, path, preview)
    button_to(path, method: :post, class: "govuk-link app-link-button", form_class: "app-link-button__form") do
      safe_join([text, preview_action_context(preview)])
    end
  end

  def preview_action_context(preview)
    tag.span(" #{preview.app_name} (#{preview.branch})", class: "govuk-visually-hidden")
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
