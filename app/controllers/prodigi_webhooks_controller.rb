class ProdigiWebhooksController < ActionController::API
  def create
    secret = ENV["PRODIGI_WEBHOOK_SECRET"].to_s
    supplied = params[:token].to_s
    unless secret.length >= 32 && ActiveSupport::SecurityUtils.secure_compare(supplied, secret)
      return head :unauthorized
    end
    return head :not_found unless ProdigiConfiguration::ENDPOINTS.key?(params[:environment])

    # A callback is a hint, not authenticated order state. Only look up a known
    # order in the fixed API environment; never request the callback's source.
    order = PhotoBookOrder.find_by(environment: params[:environment], remote_id: params[:subject].to_s)
    RefreshProdigiOrderJob.perform_later(order) if order
    head :no_content
  end
end
