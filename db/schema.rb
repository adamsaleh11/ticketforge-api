# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_06_01_185808) do
  create_schema "auth"
  create_schema "extensions"
  create_schema "graphql"
  create_schema "graphql_public"
  create_schema "pgbouncer"
  create_schema "realtime"
  create_schema "storage"
  create_schema "vault"

  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_stat_statements"
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  create_table "phases", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.integer "number", null: false
    t.string "title", null: false
    t.text "description"
    t.integer "position", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "position"], name: "index_phases_on_project_id_and_position"
    t.index ["project_id"], name: "index_phases_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "github_repo_full_name"
    t.string "llm_provider", null: false
    t.string "llm_model", null: false
    t.string "status", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "ticket_count", default: 0, null: false
    t.datetime "last_generated_at"
    t.index ["user_id"], name: "index_projects_on_user_id"
  end

  create_table "tickets", force: :cascade do |t|
    t.bigint "phase_id", null: false
    t.string "repo", null: false
    t.string "title", null: false
    t.text "body", null: false
    t.integer "position", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["phase_id", "position"], name: "index_tickets_on_phase_id_and_position"
    t.index ["phase_id"], name: "index_tickets_on_phase_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "supabase_user_id", null: false
    t.string "email", null: false
    t.string "name"
    t.string "github_username"
    t.text "github_access_token"
    t.string "ollama_endpoint", default: "http://localhost:11434", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["supabase_user_id"], name: "index_users_on_supabase_user_id", unique: true
  end

  add_foreign_key "phases", "projects"
  add_foreign_key "projects", "users"
  add_foreign_key "tickets", "phases"
end
