class TicketSerializer
  include JSONAPI::Serializer

  attributes :repo, :title, :body, :position, :status
end
