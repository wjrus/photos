class PhotoSearch
  FILTER_PARAMS = %i[q camera_make camera_model lens_model person_id place_id].freeze
  PUBLIC_FILTER_PARAMS = %i[q].freeze

  def self.filter_params_for(user)
    user.present? ? FILTER_PARAMS : PUBLIC_FILTER_PARAMS
  end

  attr_reader :params, :user

  def initialize(params:, user:, semantic: true, scope: nil)
    @params = params.symbolize_keys.slice(*self.class.filter_params_for(user))
    @user = user
    @semantic = semantic
    @scope = scope || Photo.visible_to(user)
  end

  def results
    scope = @scope
      .left_outer_joins(:metadata)

    scope = apply_text(scope)
    scope = apply_metadata_filters(scope)
    scope = apply_person_filter(scope)
    scope = apply_place_filter(scope)

    # Filter with a subquery so multiple matching tags/albums cannot duplicate
    # photos. Sort and preload only the resulting photos, not the joined rows.
    Photo.where(id: scope.select(:id)).with_original_variant_records.stream_order
  end

  def active?
    self.class.filter_params_for(user).any? { |key| params[key].present? }
  end

  def semantic_search_available?
    PhotoOpenclipSearch.available_for?(user)
  end

  private

  def apply_text(scope)
    return scope if params[:q].blank?

    query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip)}%"
    return scope.where("photos.title ILIKE ?", query) if user.blank?

    album_ids = PhotoAlbum.visible_to(user).where("photo_albums.title ILIKE ?", query).select(:id)
    tagged_user_ids = User.where("users.name ILIKE :query OR users.email ILIKE :query", query: query).select(:id)
    # Membership subqueries avoid multiplying candidate rows by every album/tag pair.
    album_photo_ids = PhotoAlbumMembership.where(photo_album_id: album_ids).select(:photo_id)
    tagged_photo_ids = PhotoPeopleTag.where(user_id: tagged_user_ids).select(:photo_id)
    location_photo_ids = PhotoMetadata.where(photo_place_id: PhotoPlace.matching_name(query).select(:id)).select(:photo_id)
    semantic_photo_ids = semantic_enabled? ? PhotoOpenclipSearch.search_ids(query: params[:q], user: user) : []

    scope
      .where(
        text_conditions(semantic_photo_ids),
        query: query,
        album_photo_ids: album_photo_ids,
        tagged_photo_ids: tagged_photo_ids,
        location_photo_ids: location_photo_ids,
        semantic_photo_ids: semantic_photo_ids,
        normalized_visual_tag: params[:q].to_s.strip.downcase.tr(" ", "_")
      )
  end

  def text_conditions(semantic_photo_ids)
    conditions = [
      "photos.title ILIKE :query",
      "photos.description ILIKE :query",
      "photos.original_filename ILIKE :query",
      "photo_metadata.camera_make ILIKE :query",
      "photo_metadata.camera_model ILIKE :query",
      "photo_metadata.lens_model ILIKE :query",
      "photos.id IN (:album_photo_ids)",
      "photos.id IN (:tagged_photo_ids)",
      "photos.id IN (:location_photo_ids)",
      "photos.id IN (SELECT photo_id FROM photo_analysis_runs WHERE provider = 'openrouter' AND status = 'complete' AND summary ILIKE :query)",
      "photos.id IN (SELECT photo_id FROM photo_analysis_tags WHERE provider = 'openrouter' AND name = :normalized_visual_tag)"
    ]

    conditions << "photos.id IN (:semantic_photo_ids)" if semantic_photo_ids.any?

    conditions.join(" OR ")
  end

  def semantic_enabled?
    @semantic
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

    return scope.none unless PhotoLocation.valid_id?(params[:place_id])

    PhotoLocation.scope_for(scope, params[:place_id])
  end
end
