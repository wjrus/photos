class PhotoBookExport < ApplicationRecord
  belongs_to :photo_book, inverse_of: :exports
  has_one_attached :document

  validates :status, inclusion: { in: %w[pending processing ready failed] }
  validates :snapshot, :design_digest, :filename, presence: true

  def ready?
    status == "ready" && document.attached?
  end

  def source_photos_available?
    sources = snapshot.fetch("photos")
    available = photo_book.eligible_photos.where(id: sources.map { |source| source.fetch("id") }).with_attached_original.index_by(&:id)
    sources.all? { |source| source.fetch("blob_id").present? && available[source.fetch("id")]&.original&.blob&.id == source.fetch("blob_id") }
  end
end
