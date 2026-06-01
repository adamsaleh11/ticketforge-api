class User < ApplicationRecord
  # JTIMatcher: each user carries a single `jti`. Issued JWTs embed it; logout
  # rotates it, revoking all of that user's outstanding tokens at once.
  include Devise::JWT::RevocationStrategies::JTIMatcher

  # Minimal API-only module set. No :recoverable, :rememberable, :confirmable,
  # or :trackable — see plans/scaffold-initial-app.md.
  devise :database_authenticatable, :registerable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: self
end
