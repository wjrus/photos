class AppSetting < ApplicationRecord
  ORIGINAL_FILE_AUTO_HEAL = "original_file_auto_heal".freeze
  ANALYSIS_OPENCLIP_ENABLED = "analysis_openclip_enabled".freeze
  ANALYSIS_YOLO_ENABLED = "analysis_yolo_enabled".freeze
  ANALYSIS_OPENAI_ENABLED = "analysis_openai_enabled".freeze
  ANALYSIS_OPENAI_PUBLIC_ONLY = "analysis_openai_public_only".freeze
  ANALYSIS_OPENAI_REQUIRE_OWNER_CONFIRM = "analysis_openai_require_owner_confirm".freeze

  ANALYSIS_BOOLEAN_SETTINGS = {
    ANALYSIS_OPENCLIP_ENABLED => false,
    ANALYSIS_YOLO_ENABLED => false,
    ANALYSIS_OPENAI_ENABLED => false,
    ANALYSIS_OPENAI_PUBLIC_ONLY => true,
    ANALYSIS_OPENAI_REQUIRE_OWNER_CONFIRM => true
  }.freeze

  validates :key, presence: true, uniqueness: true

  class << self
    def boolean(key, default:)
      setting = find_by(key: key)
      return default if setting.nil?

      ActiveModel::Type::Boolean.new.cast(setting.value)
    end

    def set_boolean!(key, enabled)
      setting = find_or_initialize_by(key: key)
      setting.value = ActiveModel::Type::Boolean.new.cast(enabled).to_s
      setting.save!
      setting
    end
  end
end
