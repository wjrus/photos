class PhotoAnalysisTag < ApplicationRecord
  belongs_to :photo
  belongs_to :photo_analysis_run

  validates :provider, inclusion: { in: PhotoAnalysisRun::PROVIDERS }
  validates :name, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :name, uniqueness: { scope: [ :photo_id, :provider ] }
  validates :raw, presence: true

  normalizes :name, with: ->(name) { name.to_s.strip.downcase.tr(" ", "_") }
  normalizes :category, with: ->(category) { category.to_s.strip.downcase.presence }
end
