class AddIndexToS3Filename < ActiveRecord::Migration[5.1]
  def change
    add_index(:runs, :s3_filename)
  end
end
