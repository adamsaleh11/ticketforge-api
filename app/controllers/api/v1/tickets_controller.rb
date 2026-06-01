module Api
  module V1
    class TicketsController < ApplicationController
      # PATCH /api/v1/tickets/:id
      # Status-only update. Transitions are unconstrained: any of
      # pending/in_progress/done may be set from any current value.
      def update
        ticket = find_ticket

        status = ticket_params[:status]
        unless Ticket.statuses.key?(status)
          return render json: invalid_status_error, status: :unprocessable_entity
        end

        ticket.update!(status: status)
        render json: TicketSerializer.new(ticket).serializable_hash
      end

      private

      # Scope through phase -> project -> user so another user's (or a missing)
      # ticket raises RecordNotFound -> 404, never leaking existence. No
      # User#tickets association exists; the join lives here.
      def find_ticket
        Ticket.joins(phase: :project)
              .where(projects: { user_id: current_user.id })
              .find(params[:id])
      end

      def ticket_params
        # status is the only mutable field; generated content stays immutable.
        params.require(:ticket).permit(:status)
      end

      def invalid_status_error
        {
          errors: [{
            source: { pointer: "/data/attributes/status" },
            detail: "is not a valid status"
          }]
        }
      end
    end
  end
end
