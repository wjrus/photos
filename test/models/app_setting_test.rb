require "test_helper"

class AppSettingTest < ActiveSupport::TestCase
  test "boolean returns default when unset" do
    AppSetting.where(key: AppSetting::ORIGINAL_FILE_AUTO_HEAL).delete_all

    assert_equal false, AppSetting.boolean(AppSetting::ORIGINAL_FILE_AUTO_HEAL, default: false)
    assert_equal true, AppSetting.boolean(AppSetting::ORIGINAL_FILE_AUTO_HEAL, default: true)
  end

  test "set boolean persists value" do
    AppSetting.set_boolean!(AppSetting::ORIGINAL_FILE_AUTO_HEAL, true)

    assert_equal true, AppSetting.boolean(AppSetting::ORIGINAL_FILE_AUTO_HEAL, default: false)

    AppSetting.set_boolean!(AppSetting::ORIGINAL_FILE_AUTO_HEAL, false)

    assert_equal false, AppSetting.boolean(AppSetting::ORIGINAL_FILE_AUTO_HEAL, default: true)
  end
end
