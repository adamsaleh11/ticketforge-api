class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :supabase_user_id, null: false
      t.string :email, null: false
      t.string :name
      t.string :github_username
      t.text :github_access_token
      t.string :ollama_endpoint, null: false, default: "http://localhost:11434"

      t.timestamps
    end

    add_index :users, :supabase_user_id, unique: true
  end
end
