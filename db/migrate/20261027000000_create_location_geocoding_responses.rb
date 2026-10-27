class CreateLocationGeocodingResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :location_geocoding_responses do |t|
      t.string :request_key, null: false
      t.jsonb :payload, null: false
      t.timestamps
    end
    add_index :location_geocoding_responses, :request_key, unique: true
  end
end
