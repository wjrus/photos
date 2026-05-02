require "application_system_test_case"

class HomeTest < ApplicationSystemTestCase
  test "visiting the photo stream" do
    visit root_path

    assert_text "wjr photos"
    assert_button "Sign in"
    assert_no_text "ARCHIVE RULE"

    find("summary", text: "wjr photos").click
    assert_text "ORIGINALS"
    assert_text "Preserved privately."
  end
end
