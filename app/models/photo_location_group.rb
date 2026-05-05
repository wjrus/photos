class PhotoLocationGroup
  include ActiveModel::Model

  attr_accessor :id, :title, :photo_count, :newest_at, :oldest_at, :representative_photo_id, :location_ids

  def initialize(...)
    super
    self.photo_count ||= 0
    self.location_ids ||= []
  end

  def add(location)
    self.photo_count += location.photo_count.to_i
    self.newest_at = [ newest_at, location.newest_at ].compact.max
    self.oldest_at = [ oldest_at, location.oldest_at ].compact.min
    self.representative_photo_id ||= location.representative_photo_id
    location_ids << PhotoLocation.id_for(location.latitude_bucket, location.longitude_bucket)
  end
end
