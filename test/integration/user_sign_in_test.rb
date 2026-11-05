require "test_helper"

class UserSignInTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "signs in with the correct password" do
    post user_session_url, params: { user: { email: users(:one).email, password: "password" } }

    assert_redirected_to root_url
    assert_equal users(:one).id, @request.session["warden.user.user.key"].first.first
  end

  test "rejects the wrong password" do
    post user_session_url, params: { user: { email: users(:one).email, password: "wrong-password" } }

    assert_response :unprocessable_content
    assert_nil @request.session["warden.user.user.key"]
  end

  test "registers a new user with a bcrypt-hashed password" do
    assert_difference("User.count") do
      post user_registration_url, params: {
        user: { name: "Mary Jackson", email: "mary@example.com", password: "password", password_confirmation: "password" }
      }
    end

    assert_redirected_to root_url
    assert User.find_by(email: "mary@example.com").valid_password?("password")
  end
end
