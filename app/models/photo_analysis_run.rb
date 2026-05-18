class PhotoAnalysisRun < ApplicationRecord
  PROVIDERS = %w[openclip yolo openai].freeze
  STATUSES = %w[pending running complete failed skipped].freeze
  SOURCE_VARIANTS = %w[stream display original video_preview].freeze

  belongs_to :photo
  has_many :tags, class_name: "PhotoAnalysisTag", dependent: :destroy
  has_many :objects, class_name: "PhotoAnalysisObject", dependent: :destroy
  has_one :embedding, class_name: "PhotoEmbedding", dependent: :nullify

  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :source_variant, inclusion: { in: SOURCE_VARIANTS }
  validates :model, presence: true
  validates :raw, presence: true

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }
  scope :complete, -> { where(status: "complete") }
  scope :needs_attention, -> { where(status: "failed") }
end
