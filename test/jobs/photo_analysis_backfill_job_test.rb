require "test_helper"

class PhotoAnalysisBackfillJobTest < ActiveJob::TestCase
  setup do
    @photo = attached_photo
    clear_enqueued_jobs
  end

  test "queues enabled local analysis providers" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    AppSetting.set_boolean!(AppSetting::ANALYSIS_YOLO_ENABLED, true)

    PhotoAnalysisBackfillJob.perform_now

    assert_enqueued_with(job: PhotoAnalysisOpenclipJob, args: [ @photo ])
    assert_enqueued_with(job: PhotoAnalysisYoloJob, args: [ @photo ])
  end

  test "does not queue disabled providers" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, false)
    AppSetting.set_boolean!(AppSetting::ANALYSIS_YOLO_ENABLED, false)

    PhotoAnalysisBackfillJob.perform_now

    assert_no_enqueued_jobs only: [ PhotoAnalysisOpenclipJob, PhotoAnalysisYoloJob ]
  end

  test "does not queue openclip for photos with current embedding" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    create_openclip_embedding(@photo)

    PhotoAnalysisBackfillJob.perform_now(providers: [ "openclip" ])

    assert_no_enqueued_jobs only: PhotoAnalysisOpenclipJob
  end

  test "queues openclip when existing embedding is for a different model" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    create_openclip_embedding(@photo, model: "ViT-L-14")

    PhotoAnalysisBackfillJob.perform_now(providers: [ "openclip" ])

    assert_enqueued_with(job: PhotoAnalysisOpenclipJob, args: [ @photo ])
  end

  private

  def attached_photo
    photo = users(:one).photos.new(title: "Analysis candidate")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "analysis-candidate.png",
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
      started_at: 1.minute.ago,
      finished_at: Time.current,
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
