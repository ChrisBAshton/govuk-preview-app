class CreatePreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :previews do |t|
      t.string :app_name, null: false
      t.string :branch, null: false
      t.string :slug, null: false
      t.string :status, null: false, default: "queued"
      t.integer :port
      t.string :container_id
      t.string :status_message

      t.timestamps
    end

    add_index :previews, :slug, unique: true
    add_index :previews, :port, unique: true
  end
end
