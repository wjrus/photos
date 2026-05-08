require "test_helper"

class PublicPhotoImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
  end

  test "public image preview is served as jpeg" do
    photo = attached_photo(title: "Public preview")
    photo.publish!

    get public_photo_image_path(photo)

    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_includes response.headers["Content-Disposition"], "inline"
  end

  test "private images and public videos do not expose preview images" do
    private_photo = attached_photo(title: "Private preview")
    public_video = attached_video(title: "Public video preview")
    public_video.publish!

    get public_photo_image_path(private_photo)
    assert_response :not_found

    get public_photo_image_path(public_video)
    assert_response :not_found
  end

  private

  def attached_photo(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

  def attached_video(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "#{title.parameterize}.mov",
      content_type: "video/quicktime"
    )
    photo.save!
    photo
  end
end
