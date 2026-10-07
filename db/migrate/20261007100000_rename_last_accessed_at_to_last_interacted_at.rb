# It records more than visits now: any action someone takes on a preview
# (see Preview#record_interaction!).
class RenameLastAccessedAtToLastInteractedAt < ActiveRecord::Migration[8.1]
  def change
    rename_column :previews, :last_accessed_at, :last_interacted_at
  end
end
