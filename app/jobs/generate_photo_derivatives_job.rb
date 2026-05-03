class GeneratePhotoDerivativesJob < ApplicationJob
  queue_as :derivatives

  DERIVATIVES = %i[stream display].freeze

  def perform(photo)
    return unless photo.image? && photo.original.attached?

    DERIVATIVES.each do |variant_name|
      photo.original.variant(variant_name).processed
    end
  end
end
