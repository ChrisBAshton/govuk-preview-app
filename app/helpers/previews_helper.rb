module PreviewsHelper
  # Flattens each top-level preview and its dependents (recursively) into a
  # depth-first list of [preview, depth] pairs, so the index view can render
  # a flat table with dependents visually nested beneath the app they exist
  # for - matching the real build order (a dependency only exists because
  # its parent needed it).
  def previews_with_depth(previews, depth = 0)
    previews.flat_map do |preview|
      [[preview, depth]] + previews_with_depth(preview.dependents.order(:created_at), depth + 1)
    end
  end

  def preview_app_name_cell(preview, depth)
    return preview.app_name if depth.zero?

    tag.span("↳ #{preview.app_name}", style: "padding-left: #{(depth - 1) * 1.5}em")
  end
end
