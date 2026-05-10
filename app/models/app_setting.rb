class AppSetting < ApplicationRecord
  ORIGINAL_FILE_AUTO_HEAL = "original_file_auto_heal".freeze

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
