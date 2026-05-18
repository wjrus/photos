class PhotoAnalysisObject < ApplicationRecord
  belongs_to :photo
  belongs_to :photo_analysis_run

  validates :provider, inclusion: { in: PhotoAnalysisRun::PROVIDERS }
  validates :name, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :x_min, :y_min, :x_max, :y_max,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validates :raw, presence: true

  normalizes :name, with: ->(name) { name.to_s.strip.downcase.tr(" ", "_") }
end
