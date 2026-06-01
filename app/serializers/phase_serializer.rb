class PhaseSerializer
  include JSONAPI::Serializer

  attributes :number, :title, :description, :position

  has_many :tickets, serializer: TicketSerializer
end
