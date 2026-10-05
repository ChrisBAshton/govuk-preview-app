class AddPublicHostnameToPreviews < ActiveRecord::Migration[8.1]
  def change
    add_column :previews, :public_hostname, :string
    add_index :previews, :public_hostname, unique: true
  end
end
