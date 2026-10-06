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
