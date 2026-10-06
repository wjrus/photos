class RefreshProdigiOrderJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(order) { "prodigi-refresh-#{order.id}" }, duration: 2.minutes
  discard_on ActiveJob::DeserializationError
  retry_on ProdigiClient::Error, wait: :polynomially_longer, attempts: 5

  def perform(order)
    order.reload
    return unless order.remote_id.present?

    order.record_remote!(ProdigiClient.new(environment: order.environment).order(order.remote_id))
  rescue ProdigiClient::Error => error
    order.update!(error: error.message)
    raise
  end
end
