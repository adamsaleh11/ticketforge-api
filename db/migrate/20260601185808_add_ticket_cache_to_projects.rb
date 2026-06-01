class AddTicketCacheToProjects < ActiveRecord::Migration[7.1]
  def change
    # Denormalized so the projects list (index) never runs per-project COUNT/MAX
    # over the heavy tickets table. Maintained by TicketGenerator on a successful
    # generation — the only path that creates or replaces tickets.
    add_column :projects, :ticket_count, :integer, null: false, default: 0
    add_column :projects, :last_generated_at, :datetime
  end
end
