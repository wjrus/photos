class PhotoBook < ApplicationRecord
  FORMATS = {
    "square_210" => { label: 'Square · 8.3 × 8.3"', width: 210, height: 210 },
    "square_297" => { label: 'Large square · 11.7 × 11.7"', width: 297, height: 297 },
    "landscape_a4" => { label: 'A4 landscape · 11.7 × 8.3"', width: 297, height: 210 }
  }.freeze
  # Keep 18 inside pages at minimum, and include both covers in our PDF limit.
  # This conservative range fits both the product and file-guide page counts.
  MIN_PRINTED_PAGES = 20
  MAX_PRINTED_PAGES = 122

  belongs_to :owner, class_name: "User", inverse_of: :photo_books
  belongs_to :cover_photo, class_name: "Photo", optional: true
  belongs_to :back_photo, class_name: "Photo", optional: true
  has_many :photo_book_memberships, dependent: :destroy
  has_many :photos, through: :photo_book_memberships
  has_many :pages, -> { order(:position) }, class_name: "PhotoBookPage", dependent: :destroy, inverse_of: :photo_book
  has_many :exports, -> { order(created_at: :desc, id: :desc) }, class_name: "PhotoBookExport", dependent: :destroy, inverse_of: :photo_book

  normalizes :title, with: ->(title) { title.to_s.strip }
  normalizes :cover_title, :cover_subtitle, :back_text, :spine_text, with: ->(text) { text.to_s }, apply_to_nil: true
  validates :title, presence: true, length: { maximum: 120 }
  validates :format, inclusion: { in: FORMATS.keys }
  validates :cover_layout, inclusion: { in: %w[full fit] }
  validates :cover_title, :cover_subtitle, :spine_text, length: { maximum: 200 }
  validates :back_text, length: { maximum: 2000 }
  validates :background_color, :text_color, format: { with: /\A#[0-9a-fA-F]{6}\z/ }
  validate :cover_photos_are_in_book
  after_create :create_initial_pages

  def eligible_photos
    photos.where(owner_id: owner_id, restricted: false, archived_at: nil).still_images
  end

  def add_photos!(selected_photos)
    eligible_ids = selected_photos.select do |photo|
      photo.id.present? && photo.owner_id == owner_id && photo.image? && !photo.restricted? && photo.archived_at.nil?
    end.map(&:id).uniq
    with_lock do
      existing_ids = photo_book_memberships.where(photo_id: eligible_ids).pluck(:photo_id)
      new_ids = eligible_ids - existing_ids
      added = photo_book_memberships.insert_all(new_ids.map { |photo_id| { photo_id: photo_id } }, unique_by: [ :photo_book_id, :photo_id ]) if new_ids.any?
      count = added&.rows&.size || 0
      touch if count.positive?
      count
    end
  end

  def remove_photo!(photo_id)
    with_lock do
      pages.where(primary_photo_id: photo_id).each { |page| page.update!(primary_photo_id: nil) }
      pages.where(secondary_photo_id: photo_id).each { |page| page.update!(secondary_photo_id: nil) }
      self.cover_photo_id = nil if cover_photo_id == photo_id.to_i
      self.back_photo_id = nil if back_photo_id == photo_id.to_i
      save!
      photo_book_memberships.find_by!(photo_id: photo_id).destroy!
      touch
    end
  end

  def append_page!(layout: "blank")
    with_lock do
      if layout == "spread" && pages.sum { |page| page.page_span }.even?
        pages.create!(position: next_position, layout: "blank")
      end
      page = pages.create!(position: next_position, layout: layout)
      touch
      page
    end
  end

  def dimensions
    FORMATS.fetch(format)
  end

  def design_snapshot
    page_data = pages.reload.map { |page| page.attributes.slice(*PhotoBookPage::DESIGN_ATTRIBUTES).merge("id" => page.id) }
    ids = ([ cover_photo_id, back_photo_id ] + page_data.flat_map do |page|
      case page.fetch("layout")
      when "blank", "text" then []
      when "two_horizontal", "two_vertical" then page.values_at("primary_photo_id", "secondary_photo_id")
      else [ page["primary_photo_id"] ]
      end
    end).compact.uniq
    photo_data = photos.where(id: ids).includes(:print_metadata, original_attachment: :blob).map do |photo|
      width, height = self.class.oriented_dimensions(photo)
      { "id" => photo.id, "blob_id" => photo.original.blob&.id, "width" => width, "height" => height }
    end
    attributes.slice("title", "format", "cover_layout", "cover_title", "cover_subtitle", "back_text", "spine_text", "background_color", "text_color", "cover_photo_id", "back_photo_id")
      .merge("version" => 1, "pages" => page_data, "photos" => photo_data.sort_by { |photo| photo.fetch("id") })
  end

  def design_digest
    Digest::SHA256.hexdigest(design_snapshot.to_json)
  end

  def self.oriented_dimensions(photo)
    metadata = photo.print_metadata
    dimensions = [ metadata&.width, metadata&.height ]
    (5..8).cover?(metadata&.orientation.to_i) ? dimensions.reverse : dimensions
  end

  private

  def create_initial_pages
    18.times { |position| pages.create!(position: position) }
  end

  def next_position
    (pages.maximum(:position) || -1) + 1
  end

  def cover_photos_are_in_book
    [ :cover_photo_id, :back_photo_id ].each do |attribute|
      next if self[attribute].blank?

      errors.add(attribute, "must be an available photo assigned to this book") unless eligible_photos.exists?(id: self[attribute])
    end
  end
end
