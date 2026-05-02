module ApplicationHelper
  def photo_display_image_path(photo)
    display_photo_path(photo)
  end

  def photo_original_media_path(photo)
    media_photo_path(photo)
  end

  def photo_stream_media(photo, **options)
    if photo.video?
      if current_user&.owner?
        video_tag photo_original_media_path(photo),
          { class: "size-full object-cover", muted: true, playsinline: true, preload: "metadata" }.merge(options)
      else
        tag.div class: "flex size-full items-center justify-center bg-zinc-900 text-xs font-semibold uppercase tracking-[0.18em] text-white/70" do
          "Video"
        end
      end
    else
      image_tag photo_display_image_path(photo), { alt: photo.title, class: "size-full object-cover" }.merge(options)
    end
  end

  def photo_detail_media(photo)
    if photo.video?
      if current_user&.owner?
        video_tag photo_original_media_path(photo),
          controls: true,
          preload: "metadata",
          class: "max-h-[calc(100vh-3rem)] w-auto max-w-full rounded-lg object-contain shadow-2xl"
      else
        tag.div class: "mx-auto flex min-h-80 w-full max-w-xl items-center justify-center rounded-lg border border-white/15 bg-white/5 p-8 text-center text-sm leading-6 text-white/75 shadow-2xl" do
          "Video playback will be available after a public-safe derivative is generated."
        end
      end
    else
      image_tag photo_display_image_path(photo),
        alt: photo.title,
        class: "max-h-[calc(100vh-3rem)] w-auto rounded-lg object-contain shadow-2xl"
    end
  end

  def photo_map_embed_url(metadata)
    latitude = metadata.latitude.to_f
    longitude = metadata.longitude.to_f
    padding = 0.012
    bbox = [
      longitude - padding,
      latitude - padding,
      longitude + padding,
      latitude + padding
    ].join(",")

    "https://www.openstreetmap.org/export/embed.html?bbox=#{bbox}&layer=mapnik&marker=#{latitude},#{longitude}"
  end

  def photo_map_link(metadata)
    "https://www.openstreetmap.org/?mlat=#{metadata.latitude}&mlon=#{metadata.longitude}#map=13/#{metadata.latitude}/#{metadata.longitude}"
  end
end
