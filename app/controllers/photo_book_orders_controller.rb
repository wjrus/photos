class PhotoBookOrdersController < ApplicationController
  include ActionController::Live
  owner_access_message "Only the owner can order photobooks."
  before_action :require_owner!
  before_action :set_book
  before_action :set_order, only: %i[show quote submit refresh spine destroy]
  before_action -> { response.set_header("Cache-Control", "private, no-store") }

  def new
    @export = @book.exports.find(params[:export_id])
    raise ActiveRecord::RecordNotFound unless @export.ready? && @export.source_photos_available?

    @order = @export.orders.new(environment: ProdigiConfiguration.environment, recipient: { "address" => { "countryCode" => "US" } })
    prepare_configuration
  end

  def create
    @export = @book.exports.find(params[:export_id])
    @order = @export.orders.new(order_params.merge(environment: ProdigiConfiguration.environment, sku: ProdigiConfiguration.sku(@export.snapshot.fetch("format"))))
    if @order.save
      begin
        ProdigiBookQuote.new(@order).call
      rescue ProdigiClient::Error => error
        @order.update!(error: error.message)
      end
      redirect_to photo_book_order_path(@book, @order)
    else
      prepare_configuration
      render :new, status: :unprocessable_entity
    end
  rescue ProdigiClient::Error => error
    redirect_to new_photo_book_order_path(@book, export_id: @export.id), alert: error.message
  end

  def show
    return render json: { version: @order.updated_at.iso8601(6) } if request.format.json?

    prepare_configuration
    begin
      ProdigiConfiguration.allow_submission!(@order.environment)
    rescue ProdigiClient::Error => error
      @submission_error = error.message
    end
  end

  def quote
    ProdigiBookQuote.new(@order).call
    redirect_to photo_book_order_path(@book, @order), notice: "Quote refreshed."
  rescue ProdigiClient::Error => error
    redirect_to photo_book_order_path(@book, @order), alert: error.message
  end

  def submit
    unless params[:confirm_order] == "1"
      return redirect_to photo_book_order_path(@book, @order), alert: "Review the PDF, address, and price, then confirm the order."
    end
    @order.approve!(reviewed_quote: params[:reviewed_quote])
    # Repeated confirmations recover an interrupted enqueue using the same
    # frozen order. Duplicate jobs are harmless because the API is idempotent.
    SubmitProdigiOrderJob.perform_later(@order) unless @order.reload.remote_id
    redirect_to photo_book_order_path(@book, @order), notice: "Order queued for Prodigi."
  rescue ProdigiClient::Error => error
    redirect_to photo_book_order_path(@book, @order), alert: error.message
  end

  def refresh
    RefreshProdigiOrderJob.perform_later(@order) if @order.remote_id.present?
    redirect_to photo_book_order_path(@book, @order), notice: "Checking the latest order status."
  end

  def spine
    raise ActiveRecord::RecordNotFound unless @order.spine_document.attached? && @order.artwork_available?

    send_stream(filename: "photobook-spine.pdf", type: "application/pdf", disposition: "attachment") do |stream|
      @order.spine_document.blob.download { |chunk| stream.write(chunk) }
    end
  end

  def destroy
    @order.with_lock do
      if @order.approved_at
        return redirect_to photo_book_order_path(@book, @order), alert: "Confirmed orders must be managed in Prodigi."
      end
      @order.destroy!
    end
    redirect_to photo_book_path(@book, anchor: "book-orders"), notice: "Order draft discarded."
  end

  private

  def set_book
    @book = current_user.photo_books.find(params[:photo_book_id])
  end

  def set_order
    @order = PhotoBookOrder.joins(:photo_book_export).where(photo_book_exports: { photo_book_id: @book.id }).find(params[:id])
    @export = @order.photo_book_export
  end

  def order_params
    params.require(:photo_book_order).permit(:copies, :shipping_method, :currency,
      recipient: [ *PhotoBookOrder::RECIPIENT_FIELDS, { address: PhotoBookOrder::ADDRESS_FIELDS } ])
  end

  def prepare_configuration
    @configuration_error = nil
    @webhook_url = ProdigiConfiguration.webhook_url(@order.environment)
    ProdigiConfiguration.api_key(@order.environment)
    ProdigiConfiguration.sku(@export.snapshot.fetch("format"))
  rescue ProdigiClient::Error => error
    @configuration_error = error.message
  end
end
