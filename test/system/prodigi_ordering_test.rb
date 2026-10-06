require "application_system_test_case"
require "axe/dsl"
require_relative "../support/prodigi_test_helper"

class ProdigiOrderingTest < ApplicationSystemTestCase
  include ProdigiTestHelper

  setup do
    configure_prodigi
    @book, _, @export = ready_order_export
    owner = users(:one)
    owner.update!(password: "synthetic-password12")
    visit sign_in_path
    fill_in "Email", with: owner.email
    fill_in "Password", with: "synthetic-password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  teardown do
    restore_prodigi
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "owner reviews a price before a sandbox order and can copy the webhook URL" do
    visit photo_book_path(@book)
    click_link "Print checks & PDF"
    click_link "Print with Prodigi"
    assert_text "Sandbox: orders are tested without printing or charging your account."
    find("summary", text: "Prodigi webhook setup").click
    assert_field "Webhook URL (sandbox)", with: ProdigiConfiguration.webhook_url
    fill_in "Recipient name", with: "Synthetic Recipient"
    fill_in "Address line 1", with: "123 Example Street"
    fill_in "City", with: "Example City"
    fill_in "State / province", with: "CA"
    fill_in "Postal code", with: "00000"
    client = quote_client
    with_prodigi_method(ProdigiClient, :new, client) do
      click_button "Get price quote"
      assert_text "Estimated total: 46.70 USD"
    end
    assert_equal %i[product spine quote], client.calls
    assert_link "Review book PDF"
    assert_link "Review spine PDF"
    assert_axe_clean
    page.save_screenshot(Rails.root.join("tmp/screenshots/prodigi-review-desktop.png"))
    assert_nil @export.orders.first.approved_at
    check "I have reviewed the book and spine PDFs, delivery address, and estimated price."
    click_button "Submit sandbox test"
    assert_text "Order queued for Prodigi."
    assert_text "Submitting to Prodigi"
    assert_equal "submitting", @export.orders.first.status
    assert_no_button "Place paid order"
    order = @export.orders.first
    order.record_remote!(remote_order(order, stage: "Complete"))
    assert_text "Complete", wait: 15
    assert_button "Refresh status"
    assert_no_selector "[data-controller='prodigi-order']"
  end

  test "review remains readable on a phone and discarding a draft uses a modal" do
    order = quoted_order(@export)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit photo_book_order_path(@book, order)
    assert_text "Estimated total: 46.70 USD"
    find("summary", text: "Prodigi webhook setup").click
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    assert_axe_clean
    page.save_screenshot(Rails.root.join("tmp/screenshots/prodigi-review-phone.png"))
    click_button "Discard draft"
    assert_selector "[role='dialog']", visible: true
    within("[role='dialog']") { click_button "Cancel" }
    assert PhotoBookOrder.exists?(order.id)
    click_button "Discard draft"
    within("[role='dialog']") { click_button "Discard draft" }
    assert_text "Order draft discarded."
    assert_not PhotoBookOrder.exists?(order.id)
  end

  private

  def assert_axe_clean
    Axe::DSL.expect(page).to(Axe::Matchers.be_axe_clean.according_to("wcag2a", "wcag2aa", "wcag21a", "wcag21aa"))
    assert true
  rescue RuntimeError => error
    flunk error.message
  end
end
