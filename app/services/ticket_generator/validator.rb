class TicketGenerator
  # Validates the structural contract of an LLM-produced plan before any
  # persistence: 5-8 phases, each with 2-5 tickets, every ticket carrying a
  # repo within the Ticket enum. The first violation raises InvalidStructure.
  class Validator
    PHASE_RANGE = (5..8).freeze
    TICKET_RANGE = (2..5).freeze
    VALID_REPOS = Ticket.repos.keys.freeze

    def initialize(plan)
      @plan = plan
    end

    def validate!
      phases = @plan.is_a?(Hash) ? @plan["phases"] : nil
      reject!("plan must contain a phases array") unless phases.is_a?(Array)
      reject!("expected 5-8 phases, got #{phases.size}") unless PHASE_RANGE.cover?(phases.size)

      phases.each_with_index { |phase, index| validate_phase!(phase, index) }
      @plan
    end

    private

    def validate_phase!(phase, index)
      reject!("phase #{index} must be an object") unless phase.is_a?(Hash)
      reject!("phase #{index} must have a title") if phase["title"].to_s.strip.empty?

      tickets = phase["tickets"]
      reject!("phase #{index} must contain a tickets array") unless tickets.is_a?(Array)
      unless TICKET_RANGE.cover?(tickets.size)
        reject!("phase #{index} expected 2-5 tickets, got #{tickets.size}")
      end

      tickets.each_with_index { |ticket, t_index| validate_ticket!(ticket, index, t_index) }
    end

    def validate_ticket!(ticket, p_index, t_index)
      reject!("ticket #{p_index}.#{t_index} must be an object") unless ticket.is_a?(Hash)
      unless VALID_REPOS.include?(ticket["repo"])
        reject!("ticket #{p_index}.#{t_index} has invalid repo #{ticket["repo"].inspect}")
      end
      if ticket["title"].to_s.strip.empty? || ticket["body"].to_s.strip.empty?
        reject!("ticket #{p_index}.#{t_index} must have a title and body")
      end
    end

    def reject!(message)
      raise InvalidStructure, message
    end
  end
end
