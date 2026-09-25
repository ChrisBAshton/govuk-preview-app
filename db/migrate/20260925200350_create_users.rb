class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :uid, null: false
      t.string :email, null: false
      t.boolean :remotely_signed_out
      t.text :permissions
      t.string :organisation_slug
      t.string :organisation_content_id
      t.boolean :disabled, default: false

      t.timestamps
    end

    add_index :users, :uid, unique: true
    add_index :users, :email, unique: true
  end
end
