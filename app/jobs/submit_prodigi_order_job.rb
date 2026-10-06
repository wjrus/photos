class SubmitProdigiOrderJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(order) { "prodigi-submit-#{order.id}" }, duration: 5.minutes
  discard_on ActiveJob::DeserializationError
  retry_on ProdigiClient::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.arguments.first.update!(error: error.message)
  end
  # Retrying an identical rejected request cannot fix a validation error.
  # Keep the frozen order and its error for an explicit retry after diagnosis.
  discard_on ProdigiClient::RequestError

  def perform(order)
    order.reload
    return if order.remote_id.present? || order.approved_at.nil?

    ProdigiConfiguration.allow_submission!(order.environment)
    raise ProdigiClient::Error, "Artwork access has expired. Check this order in Prodigi before placing another." if order.asset_expires_at <= Time.current
    raise ProdigiClient::Error, "The PDF or its source photos are no longer available. Check this order in Prodigi before placing another." unless order.artwork_available?

    # Even after a timeout or a process crash, every retry serializes the same
    # approved payload and idempotency key. Prodigi remembers that key indefinitely.
    data = ProdigiClient.new(environment: order.environment).create_order(order.request_payload)
    order.record_remote!(data)
    RefreshProdigiOrderJob.perform_later(order)
  rescue ProdigiClient::Error => error
    order.update!(error: error.message)
    raise
  end
end
