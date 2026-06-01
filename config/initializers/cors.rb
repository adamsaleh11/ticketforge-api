# Be sure to restart your server when you modify this file.
#
# Cross-Origin Resource Sharing for the separate Next.js frontend (ticketforge-web).
# Allowed origins are evaluated per-request so FRONTEND_URL is honored without a
# reboot. The frontend sends the Supabase JWT in the Authorization request header,
# which is permitted via `headers: :any`.
#
# Read more: https://github.com/cyu/rack-cors
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins do |source, _env|
      allowed = ["http://localhost:3000", ENV["FRONTEND_URL"]].compact
      allowed.include?(source)
    end

    resource "*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      credentials: false
  end
end
