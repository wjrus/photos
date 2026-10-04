class PhotoBookTypography
  FONTS = {
    "garamond" => { label: "Cormorant Garamond · literary", file: "CormorantGaramond-Regular.ttf", family: "Photobook Garamond" },
    "garamond_italic" => { label: "Cormorant Garamond Italic · lyrical", file: "CormorantGaramond-Italic.ttf", family: "Photobook Garamond Italic" },
    "serif" => { label: "Noto Serif · classic", file: "NotoSerif-Regular.ttf", family: "Photobook Noto Serif" },
    "lato" => { label: "Lato Light · minimal", file: "Lato-Light.ttf", family: "Photobook Lato Light" },
    "sans" => { label: "Noto Sans · modern", file: "NotoSans-Regular.ttf", family: "Photobook Noto Sans" }
  }.freeze
  KEYS = %w[font size color shadow shadow_color alignment position].freeze
  ALIGNMENTS = %w[left center right].freeze
  POSITIONS = %w[top middle bottom].freeze
  SIZES = [ 12, 14, 16, 18, 20, 24, 28, 32, 36, 42, 48, 56, 64 ].freeze

  def self.resolve(style, full:, color:, size: 36)
    defaults = { "font" => "garamond", "size" => size, "color" => full ? "#ffffff" : color,
      "shadow" => full, "shadow_color" => "#000000", "alignment" => "center", "position" => "bottom" }
    defaults.merge(style).tap do |resolved|
      resolved["size"] = resolved.fetch("size").to_i
      resolved["shadow"] = ActiveModel::Type::Boolean.new.cast(resolved.fetch("shadow"))
    end
  end

  def self.errors(style)
    return [ "must be a set of typography settings" ] unless style.is_a?(Hash)

    errors = []
    errors << "contains unsupported settings" if (style.keys - KEYS).any?
    errors << "must use an available font" if style.key?("font") && !FONTS.key?(style["font"])
    errors << "must use an available text size" if style.key?("size") && !SIZES.map(&:to_s).include?(style["size"].to_s)
    %w[color shadow_color].each do |key|
      errors << "must use a six-digit #{key.humanize.downcase}" if style.key?(key) && !/\A#[0-9a-fA-F]{6}\z/.match?(style[key].to_s)
    end
    errors << "must use left, center, or right alignment" if style.key?("alignment") && !ALIGNMENTS.include?(style["alignment"])
    errors << "must use top, middle, or bottom placement" if style.key?("position") && !POSITIONS.include?(style["position"])
    errors << "must enable or disable the shadow" if style.key?("shadow") && ![ true, false, "0", "1" ].include?(style["shadow"])
    errors
  end

  def self.font_path(key)
    Rails.root.join("app/assets/fonts", FONTS.fetch(key).fetch(:file))
  end
end
