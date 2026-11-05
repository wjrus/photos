module StoredBlobDelivery
  extend ActiveSupport::Concern

  private

  def send_stored_blob(blob, **options)
    service = blob.service
    if service.respond_to?(:path_for)
      # Resolve only persisted blob keys through the storage service. send_file
      # lets Rack/Thruster transfer local files without buffering them in Ruby.
      send_file service.path_for(blob.key), **options
    else
      send_data blob.download, **options
    end
  end
end
