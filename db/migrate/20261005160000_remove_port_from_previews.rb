# Every preview now listens on the same port in its own pod (see
# KubernetesRunner::APP_PORT), so there's nothing left to allocate.
class RemovePortFromPreviews < ActiveRecord::Migration[8.1]
  def change
    remove_index :previews, :port, unique: true
    remove_column :previews, :port, :integer
  end
end
