require "application_system_test_case"
require "axe/dsl"

class AccessibilityTest < ApplicationSystemTestCase
  setup do
    @owner = users(:one)
    @owner.update!(password: "password12")
    sign_in_as(@owner)
    @photo = attached_photo(title: "Accessible lake")
    @album = @owner.photo_albums.create!(title: "Accessible album", source: "manual")
    @album.photos << @photo
  end

  test "core owner pages pass wcag 2.1 aa axe checks" do
    [
      root_path,
      photo_path(@photo),
      albums_path,
      album_path(@album),
      search_path,
      uploads_path,
      users_path
    ].each do |path|
      visit path
      assert_axe_clean(path)
    end
  end

  private

  def assert_axe_clean(path)
    Axe::DSL.expect(page).to(
      Axe::Matchers.be_axe_clean.according_to(
        "wcag2a",
        "wcag2aa",
        "wcag21a",
        "wcag21aa"
      )
    )
    assert true, "#{path} passed axe checks"
  rescue RuntimeError => error
    flunk "Accessibility violations on #{path}:\n#{error.message}"
  end

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
