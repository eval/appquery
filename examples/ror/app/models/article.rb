class Article < ApplicationRecord
  belongs_to :author
  has_and_belongs_to_many :tags
end
