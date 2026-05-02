require "application_system_test_case"

class HomeTest < ApplicationSystemTestCase
  test "visiting the photo stream" do
    visit root_path

    assert_text "wjr photos"
    assert_button "Sign in"
    assert_no_text "ARCHIVE RULE"
    assert_no_selector "summary", text: "wjr photos"
    assert_no_text "Preserved privately."
  end
end
