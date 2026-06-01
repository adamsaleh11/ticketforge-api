class Phase < ApplicationRecord
  belongs_to :project
  has_many :tickets, -> { order(:position) }, dependent: :destroy

  validates :number, :position, presence: true
  validates :title, presence: true
end
