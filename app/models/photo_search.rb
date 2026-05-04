class PhotoSearch
  FILTER_PARAMS = %i[q camera_make camera_model lens_model person_id place_id].freeze

  attr_reader :params, :user

  def initialize(params:, user:)
    @params = params
    @user = user
  end

  def results
    scope = Photo.visible_to(user)
      .with_original_variant_records
      .left_outer_joins(:metadata)
      .includes(photo_people_tags: :user, photo_albums: [])

    scope = apply_text(scope)
    scope = apply_metadata_filters(scope)
    scope = apply_person_filter(scope)
    scope = apply_place_filter(scope)

    scope.distinct.stream_order
  end

  def active?
    FILTER_PARAMS.any? { |key| params[key].present? }
  end

  private

  def apply_text(scope)
    return scope if params[:q].blank?

    query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip)}%"
    album_ids = PhotoAlbum.visible_to(user).where("photo_albums.title ILIKE ?", query).pluck(:id)
    tagged_user_ids = User.where("users.name ILIKE :query OR users.email ILIKE :query", query: query).pluck(:id)
    location_ids = PhotoLocationPlace.where("photo_location_places.name ILIKE ?", query).pluck(:location_id)

    scope
      .left_outer_joins(:photo_albums, photo_people_tags: :user)
      .where(
        text_conditions(location_ids),
        query: query,
        album_ids: album_ids,
        tagged_user_ids: tagged_user_ids
      )
  end

  def text_conditions(location_ids)
    conditions = [
      "photos.title ILIKE :query",
      "photos.description ILIKE :query",
      "photos.original_filename ILIKE :query",
      "photo_metadata.camera_make ILIKE :query",
      "photo_metadata.camera_model ILIKE :query",
      "photo_metadata.lens_model ILIKE :query",
      "photo_albums.id IN (:album_ids)",
      "photo_people_tags.user_id IN (:tagged_user_ids)"
    ]

    location_ids.each_with_index do |location_id, index|
      latitude_bucket, longitude_bucket = PhotoLocation.parse_id(location_id)
      next unless latitude_bucket && longitude_bucket

      conditions << sanitize_location_condition(latitude_bucket, longitude_bucket, index)
    end

    conditions.join(" OR ")
  end

  def sanitize_location_condition(latitude_bucket, longitude_bucket, index)
    ActiveRecord::Base.sanitize_sql_array([
      "FLOOR(photo_metadata.latitude / :cell_size_#{index}) = :latitude_bucket_#{index} AND FLOOR(photo_metadata.longitude / :cell_size_#{index}) = :longitude_bucket_#{index}",
      {
        "cell_size_#{index}": PhotoLocation::CELL_SIZE,
        "latitude_bucket_#{index}": latitude_bucket,
        "longitude_bucket_#{index}": longitude_bucket
      }
    ])
  end

  def apply_metadata_filters(scope)
    %i[camera_make camera_model lens_model].each do |field|
      next if params[field].blank?

      scope = scope.where(photo_metadata: { field => params[field] })
    end

    scope
  end

  def apply_person_filter(scope)
    return scope if params[:person_id].blank?

    scope.joins(:photo_people_tags).where(photo_people_tags: { user_id: params[:person_id] })
  end

  def apply_place_filter(scope)
    return scope if params[:place_id].blank?

    latitude_bucket, longitude_bucket = PhotoLocation.parse_id(params[:place_id])
    return scope.none unless latitude_bucket && longitude_bucket

    PhotoLocation.scope_for(scope, PhotoLocation.id_for(latitude_bucket, longitude_bucket))
  end
end
