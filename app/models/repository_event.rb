class RepositoryEvent < ApplicationRecord
  CATEGORIES = %w[file_health queue archive storage].freeze
  SEVERITIES = %w[info warning error critical].freeze

  belongs_to :subject, polymorphic: true, optional: true

  validates :category, inclusion: { in: CATEGORIES }
  validates :event_type, :message, :occurred_at, presence: true
  validates :severity, inclusion: { in: SEVERITIES }

  scope :latest_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :unread, -> { where(read_at: nil) }
  scope :important, -> { where(severity: %w[warning error critical]) }

  def self.record!(category:, event_type:, severity:, message:, subject: nil, data: {})
    create!(
      category: category,
      event_type: event_type,
      severity: severity,
      message: message,
      subject: subject,
      data: data,
      occurred_at: Time.current
    )
  end

  def read?
    read_at.present?
  end
end
