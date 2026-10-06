require "test_helper"
require_relative "../support/prodigi_test_helper"

class PhotoBookOrdersControllerTest < ActionDispatch::IntegrationTest
  include ProdigiTestHelper
  setup do
    configure_prodigi
    @book, @photo, @export = ready_order_export
    sign_in_book_owner
  end
  teardown { restore_prodigi }

  test "shipping comparison shows only quoted methods and selection cannot supply a price or bypass ownership" do
    order = draft_order(@export)
    ProdigiBookQuote.new(order, client: quote_client(quote: synthetic_shipping_quotes)).call
    get photo_book_order_path(@book, order)
    assert_select "input[name='shipping_method']", count: 2
    assert_select "input[name='shipping_method'][value='Overnight']", count: 0
    assert_includes response.body, "17.50 USD shipping"
    assert_includes response.body, "Example Courier"
    assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) do
      post submit_photo_book_order_path(@book, order), params: { confirm_order: "1", reviewed_quote: order.quote_digest }
    end
    digest = order.quote_digest
    assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) do
      post shipping_photo_book_order_path(@book, order), params: { shipping_method: "Express", reviewed_quote: digest, amount: "0.00" }
    end
    assert_redirected_to photo_book_order_path(@book, order)
    assert_equal "Express", order.reload.shipping_method
    assert_equal BigDecimal("56.70"), order.quote_total
    post shipping_photo_book_order_path(@book, order), params: { shipping_method: "Budget", reviewed_quote: digest }
    assert_equal "Express", order.reload.shipping_method
    other_book = users(:two).photo_books.create!(title: "Other owner")
    post shipping_photo_book_order_path(other_book, order), params: { shipping_method: "Budget", reviewed_quote: order.quote_digest }
    assert_response :not_found
  end

  test "owner obtains a quote then separately confirms the reviewed price" do
    get new_photo_book_order_path(@book, export_id: @export.id)
    assert_response :success
    assert_select "input#prodigi-webhook-url[value=?]", ProdigiConfiguration.webhook_url
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_not_includes response.body, CONFIGURATION.fetch("PRODIGI_SANDBOX_API_KEY")
    client = quote_client
    with_prodigi_method(ProdigiClient, :new, client) do
      assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) do
        post photo_book_orders_path(@book, export_id: @export.id), params: { photo_book_order: { copies: 1, recipient: synthetic_recipient } }
      end
    end
    assert_equal %i[product spine quote], client.calls
    order = @export.orders.first
    assert_redirected_to photo_book_order_path(@book, order)
    get photo_book_order_path(@book, order)
    assert_response :success
    assert_select "input[value='Submit sandbox test']", count: 0
    post shipping_photo_book_order_path(@book, order), params: { shipping_method: "Budget", reviewed_quote: order.quote_digest }
    order.reload
    get photo_book_order_path(@book, order)
    assert_select "input[value='Submit sandbox test']"
    assert_select "a", text: "Review spine PDF"
    get photo_book_order_path(@book, order, format: :json)
    assert_equal({ "version" => order.updated_at.iso8601(6) }, response.parsed_body)
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) { post submit_photo_book_order_path(@book, order) }
    assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) { post submit_photo_book_order_path(@book, order), params: { confirm_order: "1", reviewed_quote: "stale" } }
    assert_enqueued_with(job: SubmitProdigiOrderJob) do
      post submit_photo_book_order_path(@book, order), params: { confirm_order: "1", reviewed_quote: order.quote_digest }
    end
    assert_equal "submitting", order.reload.status
    delete photo_book_order_path(@book, order)
    assert PhotoBookOrder.exists?(order.id)
    get photo_book_order_path(@book, order)
    assert_response :success
    assert_not_includes response.body, "Discard draft"
  end

  test "missing settings are visible and malformed delivery details never call the API" do
    ENV.delete("PRODIGI_SANDBOX_API_KEY")
    get new_photo_book_order_path(@book, export_id: @export.id)
    assert_select "input[value='Get price quote'][disabled]"
    ENV["PRODIGI_SANDBOX_API_KEY"] = CONFIGURATION.fetch("PRODIGI_SANDBOX_API_KEY")
    assert_no_difference "PhotoBookOrder.count" do
      post photo_book_orders_path(@book, export_id: @export.id), params: { photo_book_order: { copies: 0, recipient: { name: "", address: { countryCode: "US" } } } }
    end
    assert_response :unprocessable_entity
  end

  test "editing a draft repopulates every delivery and pricing field" do
    order = quoted_order(@export)
    recipient = synthetic_recipient.deep_merge("phoneNumber" => "+15555550100", "address" => { "line2" => "Unit Example" })
    order.update!(recipient: recipient, copies: 3, shipping_method: "Express", currency: "CAD")
    get photo_book_order_path(@book, order)
    assert_select "a[href=?]", edit_photo_book_order_path(@book, order), text: "Change delivery or copies"
    get edit_photo_book_order_path(@book, order)
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_select "form[action=?] input[name='_method'][value='patch']", photo_book_order_path(@book, order)
    assert_select "input[name='photo_book_order[copies]'][value='3']"
    assert_select "select[name='photo_book_order[shipping_method]']", count: 0
    assert_select "select[name='photo_book_order[currency]'] option[selected][value='CAD']"
    recipient.except("address").each { |key, value| assert_select "input[name=?][value=?]", "photo_book_order[recipient][#{key}]", value }
    recipient.fetch("address").each { |key, value| assert_select "input[name=?][value=?]", "photo_book_order[recipient][address][#{key}]", value }
  end

  test "changes update the existing draft and require review of its new quote" do
    order = quoted_order(@export)
    old_review = order.quote_digest
    old_spine_id = order.spine_document.id
    reference = order.reference
    recipient = synthetic_recipient.deep_merge("name" => " Updated Recipient ", "address" => { "line1" => " 456 Example Avenue " })
    client = quote_client(quote: synthetic_quote(amount: "70.00"))
    with_prodigi_method(ProdigiClient, :new, client) do
      assert_no_difference "PhotoBookOrder.count" do
        assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) do
          patch photo_book_order_path(@book, order), params: { photo_book_order: { copies: 2, recipient: recipient } }
        end
      end
    end
    assert_redirected_to photo_book_order_path(@book, order)
    assert_equal 2, order.reload.copies
    assert_equal "Updated Recipient", order.recipient["name"]
    assert_equal "456 Example Avenue", order.recipient.dig("address", "line1")
    assert_equal reference, order.reference
    assert_equal "sandbox", order.environment
    assert_equal @export.id, order.photo_book_export_id
    assert_equal BigDecimal("78.50"), order.quote_total
    assert_not_equal old_spine_id, order.spine_document.id
    assert_raises(ProdigiClient::Error) { order.approve!(reviewed_quote: old_review) }
  end

  test "invalid edits retain entered values while failed quotes invalidate old prices" do
    order = quoted_order(@export)
    previous_recipient = order.recipient.deep_dup
    client = Object.new
    client.define_singleton_method(:product) { |_sku| raise ProdigiClient::Error, "Synthetic product lookup failed." }
    with_prodigi_method(ProdigiClient, :new, client) do
      patch photo_book_order_path(@book, order), params: { photo_book_order: { copies: 0, recipient: synthetic_recipient.merge("name" => "Entered Recipient") } }
      assert_response :unprocessable_entity
      assert_select "input#recipient_name[value='Entered Recipient']"
      assert_equal previous_recipient, order.reload.recipient
      assert order.quote_current?
      patch photo_book_order_path(@book, order), params: { photo_book_order: { copies: 2 } }
    end
    assert_redirected_to photo_book_order_path(@book, order)
    assert_equal 2, order.reload.copies
    assert_not order.quote_current?
    assert_empty order.quote
    assert_nil order.quoted_at
    assert_not order.spine_document.attached?
    assert_equal "Synthetic product lookup failed.", order.error
  end

  test "edit endpoints enforce ownership availability and immutable confirmed orders" do
    order = quoted_order(@export)
    other_book = users(:two).photo_books.create!(title: "Other owner")
    get edit_photo_book_order_path(other_book, order)
    assert_response :not_found
    patch photo_book_order_path(other_book, order), params: { photo_book_order: { copies: 2 } }
    assert_response :not_found
    @photo.update!(restricted: true)
    get edit_photo_book_order_path(@book, order)
    assert_response :not_found
    @photo.update!(restricted: false)
    order.approve!(reviewed_quote: order.quote_digest)
    payload = order.request_payload.deep_dup
    get edit_photo_book_order_path(@book, order)
    assert_redirected_to photo_book_order_path(@book, order)
    patch photo_book_order_path(@book, order), params: { photo_book_order: { copies: 2 } }
    assert_redirected_to photo_book_order_path(@book, order)
    assert_equal 1, order.reload.copies
    assert_equal payload, order.request_payload
  end

  test "owner cannot quote or access an unavailable export or another owner's orders" do
    order = quoted_order(@export)
    other_book = users(:two).photo_books.create!(title: "Other owner")
    get photo_book_order_path(other_book, order)
    assert_response :not_found
    @photo.update!(restricted: true)
    get new_photo_book_order_path(@book, export_id: @export.id)
    assert_response :not_found
    get spine_photo_book_order_path(@book, order)
    assert_response :not_found
    assert_raises(ProdigiClient::Error) { order.approve!(reviewed_quote: order.quote_digest) }
    sign_in_book_owner(users(:two))
    assert_no_difference "PhotoBookOrder.count" do
      post photo_book_orders_path(@book, export_id: @export.id), params: { photo_book_order: { recipient: synthetic_recipient } }
    end
    assert_redirected_to root_path
    delete sign_out_path
    get photo_book_order_path(@book, order)
    assert_redirected_to root_path
  end

  test "public artwork access requires confirmation, correct signature and available sources" do
    ENV.delete("PRODIGI_PUBLIC_BASE_URL")
    order = quoted_order(@export)
    token = order.signed_id(purpose: :prodigi_artwork, expires_in: 30.days)
    delete sign_out_path
    get prodigi_print_asset_path(order, kind: "default", token: token)
    assert_response :not_found
    order.approve!(reviewed_quote: order.quote_digest)
    asset_url = order.request_payload.fetch("items").first.fetch("assets").first.fetch("url")
    uri = URI(asset_url)
    assert_equal "https", uri.scheme
    assert_equal CONFIGURATION.fetch("PHOTOS_HOST"), uri.host
    assert order.request_payload.fetch("callbackUrl").start_with?("https://#{CONFIGURATION.fetch('PHOTOS_HOST')}/webhooks/prodigi/sandbox?")
    get "#{uri.path}?#{uri.query}"
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_equal "private, no-store", response.headers["Cache-Control"]
    get prodigi_print_asset_path(order, kind: "default", token: "invalid")
    assert_response :not_found
    get prodigi_print_asset_path(order, kind: "default", token: order.signed_id(purpose: :another_purpose))
    assert_response :not_found
    get prodigi_print_asset_path(order, kind: "original", token: token)
    assert_response :not_found
    @photo.update!(restricted: true)
    get "#{uri.path}?#{uri.query}"
    assert_response :not_found
    @photo.update!(restricted: false)
    travel_to 31.days.from_now do
      get "#{uri.path}?#{uri.query}"
      assert_response :not_found
    end
  end

  test "webhooks authenticate and fetch known order status without trusting payload or source" do
    order = quoted_order(@export)
    order.approve!(reviewed_quote: order.quote_digest)
    order.record_remote!(remote_order(order))
    event = { id: "evt_synthetic", subject: order.remote_id, source: "http://127.0.0.1/private", data: { order: { status: { stage: "Complete" } } } }
    assert_no_enqueued_jobs do
      post prodigi_webhook_path(environment: "sandbox"), params: event, as: :json
    end
    assert_response :unauthorized
    assert_enqueued_with(job: RefreshProdigiOrderJob, args: [ order ]) do
      post prodigi_webhook_path(environment: "sandbox", token: CONFIGURATION.fetch("PRODIGI_WEBHOOK_SECRET")), params: event, as: :json
    end
    assert_response :no_content
    assert_equal "InProgress", order.reload.remote_status["stage"]
    assert_no_enqueued_jobs do
      post prodigi_webhook_path(environment: "live", token: CONFIGURATION.fetch("PRODIGI_WEBHOOK_SECRET")), params: event, as: :json
      assert_response :no_content
      post prodigi_webhook_path(environment: "sandbox", token: CONFIGURATION.fetch("PRODIGI_WEBHOOK_SECRET")), params: event.merge(subject: "ord_unknown"), as: :json
      assert_response :no_content
    end
  end

  test "draft deletion uses an app modal and confirmed orders preserve book history" do
    order = quoted_order(@export)
    get photo_book_order_path(@book, order)
    assert_select "[role=dialog]", 1
    assert_select "button[data-action='confirm-modal#open']", text: "Discard draft"
    assert_difference "PhotoBookOrder.count", -1 do
      delete photo_book_order_path(@book, order)
    end
    order = quoted_order(@export)
    order.approve!(reviewed_quote: order.quote_digest)
    assert_no_difference("PhotoBook.count") { delete photo_book_path(@book) }
    assert_redirected_to photo_book_path(@book)
  end
end
