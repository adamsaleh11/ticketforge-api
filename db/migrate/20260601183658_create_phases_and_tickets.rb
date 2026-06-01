class CreatePhasesAndTickets < ActiveRecord::Migration[7.1]
  def change
    create_table :phases do |t|
      t.references :project, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :title, null: false
      t.text :description
      t.integer :position, null: false

      t.timestamps
    end
    add_index :phases, %i[project_id position]

    create_table :tickets do |t|
      t.references :phase, null: false, foreign_key: true
      t.string :repo, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.integer :position, null: false
      t.string :status, null: false, default: "pending"

      t.timestamps
    end
    add_index :tickets, %i[phase_id position]
  end
end
