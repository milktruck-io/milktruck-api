require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "password is stored as a bcrypt hash, never in plain text" do
    user = User.create!(name: "Alan Turing", username: "alan",
                        email: "alan@example.com", password: "enigma1936")

    assert_not_equal "enigma1936", user.encrypted_password
    assert_match(/\A\$2[aby]\$/, user.encrypted_password)
    assert_not_includes User.column_names, "password"
  end

  test "valid_password? verifies against the stored hash" do
    user = User.create!(name: "Alan Turing", username: "alan",
                        email: "alan@example.com", password: "enigma1936")

    assert user.valid_password?("enigma1936")
    assert_not user.valid_password?("enigma1937")
  end

  test "the same password hashes differently for each user" do
    one = User.create!(name: "One", username: "one-user", email: "one@example.com", password: "password")
    two = User.create!(name: "Two", username: "two-user", email: "two@example.com", password: "password")

    assert_not_equal one.encrypted_password, two.encrypted_password
  end

  test "requires email and a password of at least six characters" do
    user = User.new(name: "No Password", username: "nopass")
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
    assert_includes user.errors[:password], "can't be blank"

    user.email = "nopass@example.com"
    user.password = "short"
    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 6 characters)"
  end

  test "username is downcased and stripped" do
    user = User.create!(name: "Mixed Case", username: "  MixedCase  ",
                        email: "mixed@example.com", password: "password")

    assert_equal "mixedcase", user.username
  end

  test "username is derived from the name when blank, de-duplicating with a suffix" do
    first = User.create!(name: "Ada Lovelace", email: "ada2@example.com", password: "password")
    second = User.create!(name: "Ada Lovelace", email: "ada3@example.com", password: "password")

    # users(:one) already holds "ada"
    assert_equal "adalovelace", first.username
    assert_equal "adalovelace1", second.username
  end

  test "rejects usernames with invalid characters" do
    user = User.new(name: "Bad Username", username: "not a username!",
                    email: "bad@example.com", password: "password")

    assert_not user.valid?
    assert_includes user.errors[:username].first, "may only contain lowercase letters"
  end

  test "username must be unique regardless of case" do
    user = User.new(name: "Second Ada", username: "ADA",
                    email: "ada4@example.com", password: "password")

    assert_not user.valid?
    assert_includes user.errors[:username], "has already been taken"
  end
end
