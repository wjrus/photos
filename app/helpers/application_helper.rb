module ApplicationHelper
  def photo_display_image_path(photo)
    display_photo_path(photo)
  end

  def photo_original_media_path(photo)
    media_photo_path(photo)
  end

  def photo_stream_media(photo, **options)
    if photo.video?
      video_tag photo_original_media_path(photo),
        { class: "size-full object-cover", muted: true, playsinline: true, preload: "metadata" }.merge(options)
    else
      image_tag photo_display_image_path(photo), { alt: photo.title, class: "size-full object-cover" }.merge(options)
    end
  end

  def photo_detail_media(photo)
    if photo.video?
      video_tag photo_original_media_path(photo),
        controls: true,
        preload: "metadata",
        class: "max-h-[calc(100vh-3rem)] w-auto max-w-full rounded-lg object-contain shadow-2xl"
    else
      image_tag photo_display_image_path(photo),
        alt: photo.title,
        class: "max-h-[calc(100vh-3rem)] w-auto rounded-lg object-contain shadow-2xl"
    end
  end
end
