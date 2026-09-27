module RepositoryStatusHelper
  def repository_button_class(primary: false)
    colors = primary ? "border-zinc-950 bg-zinc-950 text-white hover:border-teal-700 hover:bg-teal-700" : "border-zinc-300 bg-white text-zinc-800 hover:border-zinc-950 hover:bg-zinc-950 hover:text-white"
    "inline-flex min-h-10 items-center justify-center rounded-lg border px-4 py-2 text-sm font-semibold shadow-sm transition #{colors}"
  end

  def repository_badge(label, tone: :neutral)
    colors = case tone
    when :good then "border-teal-200 bg-teal-50 text-teal-900"
    when :warning then "border-amber-200 bg-amber-50 text-amber-900"
    when :danger then "border-rose-200 bg-rose-50 text-rose-900"
    else "border-zinc-200 bg-stone-50 text-zinc-700"
    end
    tag.span(label, class: "inline-flex rounded-md border px-2 py-1 text-xs font-semibold #{colors}")
  end

  def repository_metric(label, value, detail: nil, attention: false)
    tag.div(class: "min-w-0 rounded-lg bg-stone-50 p-4") do
      safe_join([
        tag.dt(label, class: "text-xs font-semibold uppercase tracking-wider text-zinc-500"),
        tag.dd(value, class: "mt-2 break-words text-2xl font-semibold #{attention ? 'text-rose-800' : 'text-zinc-950'}"),
        (tag.dd(detail, class: "mt-1 text-xs leading-5 text-zinc-500") if detail.present?)
      ].compact)
    end
  end

  def repository_analysis_setting_label(key)
    {
      AppSetting::ANALYSIS_OPENCLIP_ENABLED => "OpenCLIP semantic search",
      AppSetting::ANALYSIS_YOLO_ENABLED => "YOLO object detection",
      AppSetting::ANALYSIS_OPENAI_ENABLED => "OpenAI vision enrichment",
      AppSetting::ANALYSIS_OPENAI_PUBLIC_ONLY => "OpenAI public photos only",
      AppSetting::ANALYSIS_OPENAI_REQUIRE_OWNER_CONFIRM => "OpenAI requires owner confirmation",
      AppSetting::ANALYSIS_OPENROUTER_ENABLED => "OpenRouter Qwen vision captions",
      AppSetting::ANALYSIS_OPENROUTER_AUTO_NEW_ENABLED => "OpenRouter captions for new uploads"
    }.fetch(key)
  end

  def repository_timestamp(value)
    return "Not yet" if value.blank?

    time = value.in_time_zone
    tag.time(time.strftime("%b %-d, %-I:%M %p"), datetime: time.iso8601, title: time.strftime("%B %-d, %Y at %-I:%M:%S %p %Z"))
  end
end
