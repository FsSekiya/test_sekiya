class Branch < ApplicationRecord
  belongs_to :company
  has_many :workers, dependent: :destroy
end
