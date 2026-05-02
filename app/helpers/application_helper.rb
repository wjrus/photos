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
          "Video derivative unavailable."
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

  def photo_visibility_badge(photo)
    label = photo.public? ? "Public" : "Private"
    icon = photo.public? ? "globe" : "key"

    photo_status_badge(label, icon)
  end

  def photo_checksum_badge(photo)
    photo_status_badge("SHA-256 #{photo.checksum_status}", "badge-check")
  end

  def photo_drive_badge(photo)
    photo_status_badge("Drive #{photo.archive_status}", "drive")
  end

  def photo_icon(name, classes: "size-4")
    tag.svg(
      xmlns: "http://www.w3.org/2000/svg",
      viewBox: "0 0 24 24",
      fill: "none",
      stroke: "currentColor",
      stroke_width: "1.8",
      stroke_linecap: "round",
      stroke_linejoin: "round",
      class: classes,
      aria: { hidden: true }
    ) do
      safe_join(photo_icon_paths(name))
    end
  end

  private

  def photo_status_badge(label, icon)
    tag.span(
      class: "inline-flex size-8 items-center justify-center rounded-lg border border-white/35 bg-black/35 text-white shadow-sm backdrop-blur",
      title: label,
      aria: { label: label }
    ) do
      photo_icon(icon)
    end
  end

  def photo_icon_paths(name)
    case name
    when "globe"
      [
        tag.circle(cx: 12, cy: 12, r: 9),
        tag.path(d: "M3 12h18"),
        tag.path(d: "M12 3a14 14 0 0 1 0 18"),
        tag.path(d: "M12 3a14 14 0 0 0 0 18")
      ]
    when "key"
      [
        tag.circle(cx: 8, cy: 15, r: 4),
        tag.path(d: "M11 12 21 2"),
        tag.path(d: "m16 7 2 2"),
        tag.path(d: "m19 4 2 2")
      ]
    when "badge-check"
      [
        tag.path(d: "M12 3 5 6v5c0 4.2 2.9 7.7 7 9 4.1-1.3 7-4.8 7-9V6l-7-3Z"),
        tag.path(d: "m9 12 2 2 4-5")
      ]
    when "drive"
      [
        tag.path(d: "M9 3h6l6 10-3 5H6l-3-5 6-10Z"),
        tag.path(d: "m9 3 6 10"),
        tag.path(d: "M15 3 9 13"),
        tag.path(d: "M6 18 9 13h12")
      ]
    else
      []
    end
  end
end
