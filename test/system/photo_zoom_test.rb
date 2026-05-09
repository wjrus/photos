require "application_system_test_case"

class PhotoZoomTest < ApplicationSystemTestCase
  setup do
    @owner = users(:one)
    @owner.update!(password: "password12")
    sign_in_as(@owner)
    @photo = attached_photo(title: "Zoomable photo")
  end

  test "zoomed photos show minimap and expose keyboard pan region" do
    visit photo_path(@photo)

    click_button "Show zoom controls"
    click_button "Zoom in"

    assert_text "125%"
    assert_selector "[data-photo-zoom-target='minimap']:not(.hidden)"
    assert_selector "[role='region'][aria-label*='Use arrow keys to pan']"
  end

  private

  def sign_in_as(user)
    visit sign_in_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password12"
    click_button "Sign in"
  end

  def attached_photo(title:)
    Photo.create!(title: title, owner: @owner, captured_at: Time.zone.parse("2024-05-01 12:00")) do |photo|
      photo.original.attach(
        io: File.open(Rails.root.join("public/icon.png")),
        filename: "#{title.parameterize}.png",
        content_type: "image/png"
      )
    end
  end
end
