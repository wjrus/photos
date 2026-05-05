class AddVideoFieldsToPhotoMetadata < ActiveRecord::Migration[8.1]
  def change
    add_column :photo_metadata, :video_codec, :string
    add_column :photo_metadata, :video_profile, :string
    add_column :photo_metadata, :audio_codec, :string
    add_column :photo_metadata, :video_container, :string
    add_column :photo_metadata, :video_bitrate, :bigint
    add_column :photo_metadata, :video_duration, :decimal, precision: 12, scale: 3
    add_column :photo_metadata, :video_frame_rate, :decimal, precision: 10, scale: 3
  end
end
