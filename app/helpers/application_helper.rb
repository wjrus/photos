module ApplicationHelper
  BULK_ACTION_BUTTON_CLASSES = "ui-tooltip flex size-10 items-center justify-center rounded-lg text-zinc-800 transition hover:bg-zinc-100 disabled:opacity-40".freeze
  BULK_DANGER_BUTTON_CLASSES = "ui-tooltip flex size-10 items-center justify-center rounded-lg text-zinc-800 transition hover:bg-rose-50 hover:text-rose-800 disabled:opacity-40".freeze

  def photo_display_image_path(photo)
    display_photo_path(photo)
  end

  def photo_original_media_path(photo)
    media_photo_path(photo)
  end

  def photo_stream_media(photo, **options)
    if photo.video?
      photo_stream_placeholder("Video")
    else
      stream_variant = photo.processed_original_variant_record(:stream)
      return photo_stream_placeholder("Processing") unless stream_variant&.image&.attached?

      image_tag stream_variant.image,
        { alt: photo.title, class: "size-full object-cover", loading: "lazy", decoding: "async" }.merge(options)
    end
  end

  def photo_detail_media(photo)
    if photo.video?
      if current_user&.owner?
        video_tag photo_original_media_path(photo),
          controls: true,
          preload: "none",
          class: "max-h-[calc(100vh-3rem)] w-auto max-w-full rounded-lg object-contain shadow-2xl"
      else
        tag.div class: "mx-auto flex min-h-80 w-full max-w-xl items-center justify-center rounded-lg border border-white/15 bg-white/5 p-8 text-center text-sm leading-6 text-white/75 shadow-2xl" do
          "Video derivative unavailable."
        end
      end
    else
      detail_variant = photo.processed_original_variant_record(:display) || photo.processed_original_variant_record(:stream)

      if detail_variant&.image&.attached?
        image_tag detail_variant.image,
          alt: photo.title,
          class: "max-h-[calc(100vh-3rem)] w-auto rounded-lg object-contain shadow-2xl"
      else
        tag.div class: "mx-auto flex min-h-80 w-full max-w-xl items-center justify-center rounded-lg border border-white/15 bg-white/5 p-8 text-center text-sm leading-6 text-white/75 shadow-2xl" do
          "Image derivative processing."
        end
      end
    end
  end

  def photo_dimensions(metadata)
    return "unknown" unless metadata&.width.present? && metadata&.height.present?

    "#{number_with_delimiter(metadata.width)} x #{number_with_delimiter(metadata.height)}"
  end

  def photo_map_embed_url(metadata)
    return if google_maps_api_key.blank?

    query = "#{metadata.latitude},#{metadata.longitude}"
    "https://www.google.com/maps/embed/v1/place?#{URI.encode_www_form(key: google_maps_api_key, q: query, zoom: 13)}"
  end

  def photo_map_link(metadata)
    "https://www.google.com/maps/search/?api=1&#{URI.encode_www_form(query: "#{metadata.latitude},#{metadata.longitude}")}"
  end

  def google_maps_api_key
    ENV["GOOGLE_MAPS_EMBED_API_KEY"]
  end

  def photo_stream_placeholder(label)
    tag.div class: "flex size-full items-center justify-center bg-zinc-900 text-xs font-semibold uppercase tracking-[0.18em] text-white/70" do
      label
    end
  end

  def user_avatar(user, classes: "size-9 rounded-lg border border-zinc-200 object-cover")
    if user.avatar.attached?
      image_tag user.avatar, alt: "", class: classes
    elsif user.avatar_url.present?
      image_tag user.avatar_url, alt: "", class: classes
    else
      tag.span(
        user.display_name.first.to_s.upcase,
        class: "#{classes} flex items-center justify-center bg-zinc-950 text-sm font-semibold text-white"
      )
    end
  end

  def bulk_action_button(icon:, label:, value: nil, type: "submit", action: nil, danger: false, disabled: true)
    data = {
      tooltip: label,
      bulk_selection_target: "action"
    }
    data[:action] = action if action.present?

    options = {
      type: type,
      disabled: disabled,
      title: label,
      aria: { label: label },
      data: data,
      class: danger ? BULK_DANGER_BUTTON_CLASSES : BULK_ACTION_BUTTON_CLASSES
    }
    options[:name] = "bulk_action" if value.present?
    options[:value] = value if value.present?

    button_tag(**options) do
      safe_join([ app_icon(icon), tag.span(label, class: "sr-only") ])
    end
  end

  def app_icon(name, classes: "size-5")
    paths = {
      check_circle: '<path d="M9 12.75 11.25 15 15.5 9.5"/><path d="M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/>',
      archive: '<rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v11a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',
      chevron_down: '<path d="m6 9 6 6 6-6"/>',
      chevron_left: '<path d="m15 18-6-6 6-6"/>',
      chevron_up: '<path d="m18 15-6-6-6 6"/>',
      globe: '<path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Z"/><path d="M2 12h20"/><path d="M12 2c2.5 2.7 3.75 6.03 3.75 10S14.5 19.3 12 22c-2.5-2.7-3.75-6.03-3.75-10S9.5 4.7 12 2Z"/>',
      image_plus: '<path d="M16 5h6"/><path d="M19 2v6"/><path d="M21 11v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h7"/><path d="m3 16 4-4c.9-.9 2.1-.9 3 0l5 5"/><path d="m14 16 1-1c.9-.9 2.1-.9 3 0l3 3"/><path d="M8.5 9.5h.01"/>',
      lock: '<path d="M7 11V8a5 5 0 0 1 10 0v3"/><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M12 15v2"/>',
      rotate_ccw: '<path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 3v6h6"/>',
      trash: '<path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 15H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/>',
      x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'
    }

    tag.svg(
      paths.fetch(name).html_safe,
      xmlns: "http://www.w3.org/2000/svg",
      viewBox: "0 0 24 24",
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "1.9",
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      class: classes,
      aria: { hidden: true }
    )
  end
end
