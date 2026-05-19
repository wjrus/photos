require "test_helper"

class SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "search finds photos by title" do
    match = attached_photo(title: "Banff overlook")
    attached_photo(title: "Office note")

    get search_path(q: "Banff")

    assert_response :success
    assert_includes response.body, "Banff overlook"
    refute_includes response.body, "Office note"
    assert_select "a[href='#{photo_path(match)}'][data-photo-return-to*='#{search_path(q: "Banff")}'][data-photo-return-to*='search_order=']"
    assert_select "form[data-controller~='stream-state-reset'][data-controller~='search-form'][data-action='submit->stream-state-reset#clear']"
    assert_select "button[aria-label='Clear search text'][data-action='search-form#clearQuery']"
  end

  test "owner search includes openclip visual matches" do
    match = attached_photo(title: "Parking lot")
    other = attached_photo(title: "Office note")
    create_openclip_embedding(match)
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    client = FakeOpenclipSearchClient.new([ { "photo_id" => match.id, "score" => 0.92 } ])

    with_openclip_client(client) do
      get search_path(q: "car")
    end

    assert_response :success
    assert_includes response.body, "Parking lot"
    refute_includes response.body, "Office note"
    assert_includes response.body, "OpenCLIP visual search enabled"
  end

  test "opening a semantic search result does not rerun openclip for navigation" do
    match = attached_photo(title: "Parking lot")
    create_openclip_embedding(match)
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    client = FakeOpenclipSearchClient.new([ { "photo_id" => match.id, "score" => 0.92 } ])

    with_openclip_client(client) do
      get search_path(q: "car")
      assert_response :success

      get photo_path(match, return_to: search_path(q: "car"))
      assert_redirected_to photo_path(match)
      follow_redirect!
    end

    assert_response :success
    assert_equal 1, client.calls
  end

  test "search filters by camera and lens metadata" do
    match = attached_photo(title: "Fuji frame")
    match.create_metadata!(
      extraction_status: "complete",
      camera_make: "FUJIFILM",
      camera_model: "X100V",
      lens_model: "23mm F2",
      raw: {}
    )
    other = attached_photo(title: "Phone frame")
    other.create_metadata!(
      extraction_status: "complete",
      camera_make: "Apple",
      camera_model: "iPhone",
      lens_model: "Wide",
      raw: {}
    )

    get search_path(camera_model: "X100V", lens_model: "23mm F2")

    assert_response :success
    assert_includes response.body, "Fuji frame"
    refute_includes response.body, "Phone frame"
    assert_select "details[open]"
    assert_select "option[selected]", text: "X100V"
    assert_select "option[selected]", text: "23mm F2"
  end

  test "search page can focus around a returned photo" do
    newer = attached_photo(title: "Florida newer")
    target = attached_photo(title: "Florida returned")
    older = attached_photo(title: "Florida older")
    newer.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    target.update_columns(created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    older.update_columns(created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))

    get search_path(q: "Florida", photo_id: target.id)

    assert_response :success
    assert_select "[data-stream-state-target-photo-id-value='#{target.id}']"
    assert_select "[data-photo-id='#{target.id}']"
    assert_select "[data-photo-id='#{older.id}']"
  end

  test "search result return path preserves cached result order for photo navigation" do
    newest = attached_photo(title: "Dog newest")
    current = attached_photo(title: "Dog current")
    oldest = attached_photo(title: "Dog oldest")
    newest.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    current.update_columns(created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    oldest.update_columns(created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))

    with_memory_cache do
      get search_path(q: "Dog")
      assert_response :success
      return_to = css_select("a[href='#{photo_path(current)}']").first["data-photo-return-to"]
      assert_includes return_to, "search_order="

      get photo_path(current, return_to: return_to)
      assert_redirected_to photo_path(current)
      follow_redirect!
    end

    assert_response :success
    assert_select "a[href='#{photo_path(newest)}'][aria-label='Previous item in stream']"
    assert_select "a[href='#{photo_path(oldest)}'][aria-label='Next item in stream']"
  end

  test "search finds photos by place name" do
    match = attached_photo(title: "Downtown lunch")
    match.create_metadata!(
      extraction_status: "complete",
      latitude: 44.7622,
      longitude: -85.5980,
      raw: {}
    )
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.7622, -85.5980),
      name: "Traverse City, Michigan"
    )
    other = attached_photo(title: "Elsewhere lunch")

    get search_path(q: "Traverse")

    assert_response :success
    assert_includes response.body, "Downtown lunch"
    refute_includes response.body, "Elsewhere lunch"
  end

  test "search finds photos by place tag hierarchy" do
    match = attached_photo(title: "Downtown lunch")
    match.create_metadata!(
      extraction_status: "complete",
      latitude: 44.7622,
      longitude: -85.5980,
      raw: {}
    )
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.7622, -85.5980),
      name: "Traverse City, Michigan",
      names: [ "Traverse City, Michigan", "Traverse City", "Michigan", "United States" ]
    )
    other = attached_photo(title: "Elsewhere lunch")

    get search_path(q: "United States")

    assert_response :success
    assert_includes response.body, "Downtown lunch"
    refute_includes response.body, "Elsewhere lunch"
  end

  test "anonymous search does not expose advanced metadata filter options" do
    public_photo = attached_photo(title: "Public meadow")
    public_photo.publish!
    public_photo.create_metadata!(
      extraction_status: "complete",
      camera_make: "Secret Camera Co",
      camera_model: "SecretCam 9000",
      lens_model: "Secret Lens 50",
      latitude: 44.7622,
      longitude: -85.5980,
      raw: {}
    )
    public_photo.photo_people_tags.create!(user: users(:two), tagged_by: @owner)
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.7622, -85.5980),
      name: "Hidden Hamlet"
    )

    delete sign_out_path
    get search_path

    assert_response :success
    assert_select "select#person_id", false
    assert_select "select#place_id", false
    assert_select "select#camera_model", false
    assert_select "select#lens_model", false
    refute_includes response.body, users(:two).name
    refute_includes response.body, "SecretCam 9000"
    refute_includes response.body, "Secret Lens 50"
    refute_includes response.body, "Hidden Hamlet"
  end

  test "anonymous search ignores metadata and person query fields" do
    public_photo = attached_photo(title: "Public meadow")
    public_photo.publish!
    public_photo.create_metadata!(
      extraction_status: "complete",
      camera_model: "SecretCam 9000",
      lens_model: "Secret Lens 50",
      latitude: 44.7622,
      longitude: -85.5980,
      raw: {}
    )
    public_photo.photo_people_tags.create!(user: users(:two), tagged_by: @owner)
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.7622, -85.5980),
      name: "Hidden Hamlet"
    )

    delete sign_out_path

    get search_path(q: "SecretCam")
    assert_response :success
    refute_includes response.body, "Public meadow"

    get search_path(
      camera_model: "SecretCam 9000",
      lens_model: "Secret Lens 50",
      person_id: users(:two).id,
      place_id: PhotoLocation.place_id_for_name("Hidden Hamlet")
    )
    assert_response :success
    assert_includes response.body, "Public meadow"
    refute_includes response.body, "SecretCam 9000"
    refute_includes response.body, "Secret Lens 50"
    refute_includes response.body, "Hidden Hamlet"
  end

  private

  FakeOpenclipSearchClient = Struct.new(:results, :calls) do
    def initialize(results)
      super(results, 0)
    end

    def openclip_search(query:, limit:)
      self.calls += 1
      { "results" => results.first(limit) }
    end
  end

  def with_openclip_client(client)
    original_new = PhotoAnalysisLocalClient.method(:new)
    PhotoAnalysisLocalClient.define_singleton_method(:new) { client }
    yield
  ensure
    PhotoAnalysisLocalClient.define_singleton_method(:new, original_new)
  end

  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous_cache
  end

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

  def create_openclip_embedding(photo, model: "ViT-B-32", model_version: "laion2b_s34b_b79k")
    run = photo.analysis_runs.create!(
      provider: "openclip",
      model: model,
      model_version: model_version,
      status: "complete",
      raw: { "provider" => "openclip" }
    )
    photo.embeddings.create!(
      photo_analysis_run: run,
      provider: "openclip",
      model: model,
      model_version: model_version,
      dimensions: 512,
      source_variant: "display",
      index_key: "#{model}-#{model_version}/#{photo.id}.npy",
      embedded_at: Time.current,
      raw: { "provider" => "openclip" }
    )
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: {
        email: user.email,
        name: user.name,
        image: user.avatar_url
      }
    )

    post "/auth/google_oauth2"
    follow_redirect!
  end
end
