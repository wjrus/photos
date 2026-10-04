class PhotoBookPage < ApplicationRecord
  LAYOUTS = {
    "blank" => "Blank page", "full" => "Full-page photo", "fit" => "Whole photo with whitespace",
    "caption" => "Photo with caption", "two_horizontal" => "Two photos side by side",
    "two_vertical" => "Two photos stacked", "text" => "Text page", "spread" => "Photo across two pages"
  }.freeze
  DESIGN_ATTRIBUTES = %w[layout primary_photo_id secondary_photo_id caption secondary_caption show_captions image_fit primary_focus_x primary_focus_y secondary_focus_x secondary_focus_y].freeze

  belongs_to :photo_book, inverse_of: :pages
  belongs_to :primary_photo, class_name: "Photo", optional: true
  belongs_to :secondary_photo, class_name: "Photo", optional: true

  normalizes :caption, :secondary_caption, with: ->(text) { text.to_s }, apply_to_nil: true

  validates :layout, inclusion: { in: LAYOUTS.keys }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :image_fit, inclusion: { in: %w[fill fit] }
  validates :show_captions, inclusion: { in: [ true, false ] }
  validates :caption, :secondary_caption, length: { maximum: 2000 }
  validates :primary_focus_x, :primary_focus_y, :secondary_focus_x, :secondary_focus_y,
    numericality: { only_integer: true, in: 0..100 }
  validate :photos_are_in_book

  def page_span
    layout == "spread" ? 2 : 1
  end

  private

  def photos_are_in_book
    [ :primary_photo_id, :secondary_photo_id ].each do |attribute|
      next if self[attribute].blank? || !will_save_change_to_attribute?(attribute)

      errors.add(attribute, "must be an available photo assigned to this book") unless photo_book.eligible_photos.exists?(id: self[attribute])
    end
  end
end
