class AddUsageToPhotoAnalysisRuns < ActiveRecord::Migration[8.1]
  def change
    change_table :photo_analysis_runs, bulk: true do |t|
      t.string :request_id
      t.bigint :input_tokens
      t.bigint :output_tokens
      t.decimal :cost_usd, precision: 12, scale: 6
    end

    add_index :photo_analysis_runs, :request_id, unique: true, where: "request_id IS NOT NULL"
  end
end
