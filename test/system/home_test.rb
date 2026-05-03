require "application_system_test_case"

class HomeTest < ApplicationSystemTestCase
  test "visiting the photo stream" do
    visit root_path

    assert_text "wjr photos"
    assert_button "Sign in"
    assert_no_text "ARCHIVE RULE"
    assert_no_text "Drop iPhone imports here"
    assert_no_text "Preserved privately."

    find("summary", text: "wjr photos").click
    assert_link "Stream"
    assert_link "Albums"
    assert_no_link "Map"
  end
end
