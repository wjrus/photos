Rails.application.config.active_storage.track_variants = true

Rails.application.config.active_storage.variant_processor = :vips

Rails.application.config.active_storage.resolve_model_to_route = :rails_storage_redirect

Rails.application.config.active_storage.web_image_content_types = %w[
  image/png
  image/jpeg
  image/jpg
  image/gif
  image/webp
]
