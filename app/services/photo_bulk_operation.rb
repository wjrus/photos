class PhotoBulkOperation
  ACTIONS = %w[publish unpublish archive restore restrict unrestrict delete add_to_album remove_from_album set_album_cover add_to_photo_book set_location].freeze
  InvalidAction = Class.new(StandardError)

  def initialize(owner:, photos:, action:, attributes:)
    @owner, @photos, @action, @attributes = owner, photos, action.to_s, attributes
  end

  def call
    raise InvalidAction, "Select at least one photo." if @photos.empty?
    raise InvalidAction, "Choose an action." unless ACTIONS.include?(@action)
    raise InvalidAction, "Only the owner can manage photos." unless @owner.owner? && @photos.all? { |photo| photo.owner_id == @owner.id }
    prepare_location if @action == "set_location"

    Photo.transaction do
      # Lock in a consistent order while retaining the caller's selection order.
      Photo.where(id: @photos.map(&:id)).order(:id).lock.load
      @photos.each(&:reload)
      result = { action: @action, affected_count: 0, skipped_count: 0 }
      case @action
      when "publish", "unpublish", "archive", "restore", "restrict", "unrestrict", "delete"
        method = @action == "delete" ? :destroy! : "#{@action}!"
        @photos.each { |photo| photo.public_send(method) }
        result[:affected_count] = @photos.size
        verb = { "publish" => "Published", "unpublish" => "Unpublished", "archive" => "Archived",
          "restore" => "Restored", "restrict" => "Moved", "unrestrict" => "Moved", "delete" => "Removed" }.fetch(@action)
        suffix = %w[restore unrestrict].include?(@action) ? " to the stream" : (@action == "restrict" ? " to Private" : "")
        result[:message] = "#{verb} #{@photos.size} #{'photo'.pluralize(@photos.size)}#{suffix}."
      when "add_to_album"
        album = target_album
        result[:affected_count] = @photos.count { |photo| PhotoAlbumMembership.find_or_create_by!(photo: photo, photo_album: album).previously_new_record? }
        result[:album_id] = album.id
        result[:message] = "Added #{result[:affected_count]} #{'photo'.pluralize(result[:affected_count])} to #{album.title}."
      when "remove_from_album"
        album = context_album
        removed_ids = album.photo_album_memberships.where(photo_id: @photos.map(&:id)).pluck(:photo_id)
        album.photo_album_memberships.where(photo_id: removed_ids).each(&:destroy!)
        album.update!(cover_photo: album.replacement_cover(excluding_photo_ids: removed_ids)) if removed_ids.include?(album.cover_photo_id)
        result[:affected_count] = removed_ids.size
        result[:album_id] = album.id
        result[:message] = "Removed #{removed_ids.size} #{'photo'.pluralize(removed_ids.size)} from #{album.title}."
      when "set_album_cover"
        album = context_album
        raise InvalidAction, "Select exactly one photo to use as the album cover." unless @photos.one?
        album.update!(cover_photo: album.photos.visible_to(@owner).find(@photos.first.id))
        result.merge!(affected_count: 1, album_id: album.id, message: "Album cover updated.")
      when "add_to_photo_book"
        book = target_book
        result[:affected_count] = book.add_photos!(@photos)
        result[:photo_book_id] = book.id
        result[:message] = "Added #{result[:affected_count]} #{'photo'.pluralize(result[:affected_count])} to #{book.title}. Videos and photos already in the book are skipped."
      when "set_location"
        image_photos = @photos.select(&:image?)
        image_photos.each { |photo| PhotoManualLocationAssigner.assign!(photo: photo, address: @address, result: @location) }
        result[:affected_count] = image_photos.size
        result[:message] = "Set location for #{image_photos.size} #{'photo'.pluralize(image_photos.size)}."
        skipped = @photos.size - image_photos.size
        result[:message] += " Skipped #{skipped} non-image #{'item'.pluralize(skipped)}." if skipped.positive?
      end
      result[:skipped_count] = @photos.size - result[:affected_count]
      result
    end
  end

  private

  def target_album
    if @attributes[:new_album_title].present?
      @owner.photo_albums.create!(title: @attributes[:new_album_title].strip, source: "manual")
    elsif @attributes[:album_id].present?
      @owner.photo_albums.find(@attributes[:album_id])
    else
      raise InvalidAction, "Choose an album or name a new one."
    end
  end

  def context_album
    album = @owner.photo_albums.find_by(id: @attributes[:context_album_id])
    raise InvalidAction, "Open an album before #{@action == 'set_album_cover' ? 'setting its cover' : 'removing photos from it'}." unless album
    album
  end

  def target_book
    if @attributes[:new_photo_book_title].present?
      @owner.photo_books.create!(title: @attributes[:new_photo_book_title], cover_title: @attributes[:new_photo_book_title])
    elsif @attributes[:photo_book_id].present?
      @owner.photo_books.find(@attributes[:photo_book_id])
    else
      raise InvalidAction, "Choose a photobook or name a new one."
    end
  end

  def prepare_location
    @address = @attributes[:location_address].to_s.squish
    raise InvalidAction, "Enter an address or place name." if @address.blank?
    raise InvalidAction, "Select at least one image photo." unless @photos.any?(&:image?)
    @location = LocationAddressGeocoder.new.geocode(address: @address)
    raise InvalidAction, "Location not found." unless @location&.fetch(:latitude, nil).present? && @location&.fetch(:longitude, nil).present?
  end
end
