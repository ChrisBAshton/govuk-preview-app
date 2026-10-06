# When a preview was last visited (see HostRouter) - so when previews need
# more room than is free, the least recently used ones are put to sleep
# first (see PreviewCapacity).
class AddLastAccessedAtToPreviews < ActiveRecord::Migration[8.1]
  def change
    add_column :previews, :last_accessed_at, :datetime
  end
end
