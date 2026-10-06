class ProdigiPrintAssetsController < ActionController::Base
  include ActionController::Live

  def show
    order = PhotoBookOrder.find_signed(params[:token].to_s, purpose: :prodigi_artwork)
    unless order && order.id.to_s == params[:id] && order.approved_at && order.asset_expires_at > Time.current && order.artwork_available?
      return head :not_found
    end
    document = case params[:kind]
    when "default" then order.photo_book_export.document
    when "spine" then order.spine_document
    end
    return head :not_found unless document&.attached?

    response.set_header("Cache-Control", "private, no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    send_stream(filename: "photobook-#{params[:kind]}.pdf", type: "application/pdf", disposition: "inline") do |stream|
      document.blob.download { |chunk| stream.write(chunk) }
    end
  end
end
