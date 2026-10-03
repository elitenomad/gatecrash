class Organiser < ApplicationRecord
  has_many :events, dependent: :restrict_with_error

  validates :name, :email, presence: true
end
