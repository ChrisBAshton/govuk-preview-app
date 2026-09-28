class AddParentToPreviews < ActiveRecord::Migration[8.1]
  def change
    add_reference :previews, :parent, null: true, foreign_key: { to_table: :previews }
  end
end
