module AlbumLinkAccess
  extend ActiveSupport::Concern

  private

  def exchange_album_access_key(album)
    return false if params[:key].blank?

    link = AlbumAccessLink.authenticate(album: album, key: params[:key])
    return false unless link

    store_album_access_cookie(link, params[:key])
    link.record_access!
    redirect_to album_path(album), status: :see_other
    true
  end

  def album_access_link_from_cookie(album)
    return if current_user&.owner?

    key = cookies.encrypted[album_access_cookie_name(album)]
    return if key.blank?

    AlbumAccessLink.authenticate(album: album, key: key).tap do |link|
      clear_album_access_cookie(album) unless link
    end
  end

  def store_album_access_cookie(link, key)
    cookie_expiration = [ link.expires_at, 30.days.from_now ].compact.min
    cookies.encrypted[album_access_cookie_name(link.photo_album)] = {
      value: key,
      expires: cookie_expiration,
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?
    }
  end

  def clear_album_access_cookie(album)
    cookies.delete(
      album_access_cookie_name(album),
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?
    )
  end

  def album_access_cookie_name(album)
    "album_access_#{album.id}"
  end

  def album_access_photo_scope(album)
    album.photos.where(restricted: false, archived_at: nil)
  end

  def apply_album_access_response_headers
    response.set_header("Cache-Control", "private, no-store")
    response.set_header("Referrer-Policy", "no-referrer")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
  end
end
