class User < ApplicationRecord
  # :database_authenticatable stores a bcrypt hash of the password in
  # encrypted_password and exposes #valid_password?. The bcrypt cost is
  # Devise.stretches (12, or 1 in test) — see config/initializers/devise.rb.
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  VALID_USERNAME_RE = /\A[a-z0-9_-]{3,30}\z/

  validates :name, presence: true
  validates :username, presence: true,
                       uniqueness: { case_sensitive: false },
                       format: { with: VALID_USERNAME_RE,
                                 message: "may only contain lowercase letters, numbers, underscores, and hyphens (3-30 chars)" }

  before_validation :normalize_username
  before_validation :assign_username_from_name, on: :create, if: -> { username.blank? }

  private

  def normalize_username
    self.username = username&.downcase&.strip
  end

  def assign_username_from_name
    return if name.blank?
    base = name.downcase.gsub(/[^a-z0-9]/, "")
    base = "user" if base.blank?
    candidate = base
    suffix = 1
    while User.where(username: candidate).where.not(id: id).exists?
      candidate = "#{base}#{suffix}"
      suffix += 1
    end
    self.username = candidate
  end
end
