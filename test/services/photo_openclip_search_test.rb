require "test_helper"

class PhotoOpenclipSearchTest < ActiveSupport::TestCase
  test "returns visible ranked ids with current embeddings" do
    owner = users(:one)
    visible = attached_photo(owner, title: "Garage")
    stale = attached_photo(owner, title: "Old index")
    hidden = attached_photo(owner, title: "Private archive")
    hidden.update!(restricted: true)
    create_openclip_embedding(visible)
    create_openclip_embedding(hidden)
    client = FakeOpenclipSearchClient.new([
      { "photo_id" => hidden.id, "score" => 0.99 },
      { "photo_id" => stale.id, "score" => 0.98 },
      { "photo_id" => visible.id, "score" => 0.97 }
    ])
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)

    assert_equal [ visible.id ], PhotoOpenclipSearch.new(query: "car", user: owner, client: client).search_ids
  end

  test "is unavailable for non owners" do
    viewer = users(:two)
    create_openclip_embedding(attached_photo(users(:one), title: "Shared garage"))
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)

    refute PhotoOpenclipSearch.available_for?(viewer)
  end

  test "returns no semantic matches when local search times out" do
    owner = users(:one)
    create_openclip_embedding(attached_photo(owner, title: "Garage"))
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    client = TimeoutOpenclipSearchClient.new

    assert_equal [], PhotoOpenclipSearch.new(query: "car", user: owner, client: client).search_ids
  end

  private

  FakeOpenclipSearchClient = Struct.new(:results) do
    def openclip_search(query:, limit:)
      { "results" => results.first(limit) }
    end
  end

  class TimeoutOpenclipSearchClient
    def openclip_search(query:, limit:)
      raise Net::ReadTimeout
    end
  end

  def attached_photo(owner, title:)
    photo = owner.photos.new(title: title)
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
end
