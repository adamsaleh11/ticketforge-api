require 'rails_helper'

RSpec.describe User, type: :model do
  it 'persists a valid user from the factory' do
    user = create(:user)

    expect(user).to be_persisted
  end

  it 'assigns a jti on creation so JWTs can be revoked' do
    user = create(:user)

    expect(user.jti).to be_present
  end

  it 'requires a unique email (case-insensitive)' do
    create(:user, email: 'dev@example.com')
    duplicate = build(:user, email: 'DEV@example.com')

    expect(duplicate).not_to be_valid
  end

  it 'requires a password' do
    user = build(:user, password: nil)

    expect(user).not_to be_valid
  end
end
