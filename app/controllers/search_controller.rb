class SearchController < ApplicationController
  include PhotoStreamPagination

  def show
    @search_params = search_params
    search = PhotoSearch.new(params: @search_params, user: current_user)
    results = search.results
    @search_active = search.active?
    @semantic_search_available = search.semantic_search_available?
    @search_order_token = store_search_order(results) if @search_active
    @search_return_path = search_return_path
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(search_stream(results))

    return if render_photo_page_if_requested(
      return_to: @search_return_path,
      bulk_form_id: "search-photo-bulk-form",
      next_page_path: @search_return_path,
      stream_target_photo_id: @stream_target_photo_id
    )

    @albums = current_user.photo_albums.display_order if current_user&.owner?
    @filter_options = filter_options
  end

  private

  def search_params
    allowed_filters = PhotoSearch.filter_params_for(current_user)
    params.permit(*allowed_filters, :cursor, :stream_page).to_h.symbolize_keys.slice(*allowed_filters)
  end

  def store_search_order(results)
    PhotoSearchOrderSnapshot.store(scope: results.except(:includes), user: current_user, token: params[:search_order])
  end

  def search_return_path
    return search_path(@search_params) if @search_order_token.blank?

    search_path(@search_params.merge(search_order: @search_order_token))
  end

  def search_stream(results)
    Photo
      .visible_to(current_user)
      .with_original_variant_records
      .where(id: results.except(:order).select(:id))
      .stream_order
  end

  def filter_options
    return empty_filter_options unless privileged_metadata_viewer?

    metadata = PhotoMetadata
      .joins(:photo)
      .merge(Photo.visible_to(current_user))

    {
      camera_makes: metadata.where.not(camera_make: [ nil, "" ]).distinct.order(:camera_make).pluck(:camera_make),
      camera_models: metadata.where.not(camera_model: [ nil, "" ]).distinct.order(:camera_model).pluck(:camera_model),
      lenses: metadata.where.not(lens_model: [ nil, "" ]).distinct.order(:lens_model).pluck(:lens_model),
      people: User
        .joins(:photo_people_tags)
        .merge(PhotoPeopleTag.joins(:photo).merge(Photo.visible_to(current_user)))
        .distinct
        .order(:name),
      places: place_filter_options(metadata)
    }
  end

  def empty_filter_options
    {
      camera_makes: [],
      camera_models: [],
      lenses: [],
      people: [],
      places: []
    }
  end

  def place_filter_options(metadata)
    location_ids = metadata
      .where.not(latitude: nil, longitude: nil)
      .pluck(:latitude, :longitude)
      .map { |latitude, longitude| PhotoLocation.id_for_coordinates(latitude, longitude) }
      .uniq

    PhotoLocationPlace.where(location_id: location_ids).select(:name).distinct.order(:name)
  end
end
