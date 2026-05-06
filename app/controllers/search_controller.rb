class SearchController < ApplicationController
  include PhotoStreamPagination

  def show
    @search_params = search_params
    search = PhotoSearch.new(params: @search_params, user: current_user)
    @search_active = search.active?
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(search_stream(search.results))
    @albums = current_user.photo_albums.display_order if current_user&.owner?
    @filter_options = filter_options

    render_photo_page_if_requested(
      return_to: search_path(@search_params),
      bulk_form_id: "search-photo-bulk-form",
      next_page_path: search_path(@search_params),
      stream_target_photo_id: @stream_target_photo_id
    )
  end

  private

  def search_params
    params.permit(*PhotoSearch::FILTER_PARAMS, :cursor, :stream_page).to_h.symbolize_keys.slice(*PhotoSearch::FILTER_PARAMS)
  end

  def search_stream(results)
    Photo
      .visible_to(current_user)
      .with_original_variant_records
      .where(id: results.except(:order).select(:id))
      .stream_order
  end

  def filter_options
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
      places: PhotoLocationPlace.select(:name).distinct.order(:name)
    }
  end
end
