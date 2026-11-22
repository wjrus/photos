class HealthController < Rails::HealthController
  def show
    backend = ENV["PHOTOS_WEB_BACKEND"]
    response.set_header("X-Photos-Backend", backend) if backend.present?
    super
  end
end
