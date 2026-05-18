require "test_helper"

class PhotoAnalysisOpenclipJobTest < ActiveJob::TestCase
  test "records completed run and embedding metadata" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    photo = attached_photo
    client = FakeOpenclipClient.new(
      "provider" => "openclip",
      "model" => "ViT-B-32",
      "model_version" => "laion2b_s34b_b79k",
      "dimensions" => 512,
      "index_key" => "ViT-B-32-laion2b_s34b_b79k/#{photo.id}.npy"
    )

    with_openclip_client(client) do
      assert_difference [ "PhotoAnalysisRun.count", "PhotoEmbedding.count" ], 1 do
        PhotoAnalysisOpenclipJob.perform_now(photo)
      end
    end

    run = photo.analysis_runs.sole
    assert_equal "openclip", run.provider
    assert_equal "complete", run.status
    assert_equal "ViT-B-32", run.model
    assert_equal "laion2b_s34b_b79k", run.model_version

    embedding = photo.embeddings.sole
    assert_equal run, embedding.photo_analysis_run
    assert_equal 512, embedding.dimensions
    assert_equal "ViT-B-32-laion2b_s34b_b79k/#{photo.id}.npy", embedding.index_key
    assert_equal photo.id, client.calls.sole.fetch(:photo_id)
    assert File.exist?(client.calls.sole.fetch(:image_path))
    assert_equal display_blob_path(photo), client.calls.sole.fetch(:image_path)
    refute_equal photo.original.blob.service.path_for(photo.original.blob.key), client.calls.sole.fetch(:image_path)
  end

  test "uses video preview frame for video originals" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    photo = attached_video
    client = FakeOpenclipClient.new(
      "provider" => "openclip",
      "model" => "ViT-B-32",
      "model_version" => "laion2b_s34b_b79k",
      "dimensions" => 512,
      "index_key" => "ViT-B-32-laion2b_s34b_b79k/#{photo.id}.npy"
    )

    with_openclip_client(client) do
      assert_difference [ "PhotoAnalysisRun.count", "PhotoEmbedding.count" ], 1 do
        PhotoAnalysisOpenclipJob.perform_now(photo)
      end
    end

    run = photo.analysis_runs.sole
    assert_equal "complete", run.status
    assert_equal "video_preview", run.source_variant
    assert_equal photo.video_preview.blob.service.path_for(photo.video_preview.blob.key), client.calls.sole.fetch(:image_path)
  end

  test "does nothing when disabled" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, false)

    assert_no_difference "PhotoAnalysisRun.count" do
      PhotoAnalysisOpenclipJob.perform_now(attached_photo)
    end
  end

  private

  FakeOpenclipClient = Struct.new(:response, :calls, keyword_init: true) do
    def initialize(response)
      super(response: response, calls: [])
    end

    def openclip_embed(photo_id:, image_path:, source_variant:)
      calls << { photo_id: photo_id, image_path: image_path, source_variant: source_variant }
      response
    end
  end

  def with_openclip_client(client)
    original_new = PhotoAnalysisLocalClient.method(:new)
    PhotoAnalysisLocalClient.define_singleton_method(:new) { client }
    yield
  ensure
    PhotoAnalysisLocalClient.define_singleton_method(:new, original_new)
  end

  def attached_photo
    photo = users(:one).photos.new(title: "OpenCLIP candidate")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "openclip-candidate.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

  def attached_video
    photo = users(:one).photos.new(title: "OpenCLIP video candidate")
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "openclip-candidate.mov",
      content_type: "video/quicktime"
    )
    photo.video_preview.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "openclip-candidate-preview.jpg",
      content_type: "image/jpeg"
    )
    photo.save!
    photo
  end

  def display_blob_path(photo)
    blob = photo.reload.processed_original_variant_record(:display).image.blob
    blob.service.path_for(blob.key)
  end
end
