class CreateProjects < ActiveRecord::Migration[7.1]
  def change
    create_table :projects do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.string :github_repo_full_name
      t.string :llm_provider, null: false
      t.string :llm_model, null: false
      t.string :status, null: false, default: "draft"

      t.timestamps
    end
  end
end
