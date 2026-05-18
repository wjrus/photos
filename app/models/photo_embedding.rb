class PhotoEmbedding < ApplicationRecord
  belongs_to :photo
  belongs_to :photo_analysis_run, optional: true

  validates :provider, inclusion: { in: PhotoAnalysisRun::PROVIDERS }
  validates :model, :index_key, :embedded_at, presence: true
  validates :dimensions, numericality: { only_integer: true, greater_than: 0 }
  validates :source_variant, inclusion: { in: PhotoAnalysisRun::SOURCE_VARIANTS }
  validates :index_key, uniqueness: true
  validates :photo_id, uniqueness: { scope: [ :provider, :model, :model_version ] }
  validates :raw, presence: true
end
