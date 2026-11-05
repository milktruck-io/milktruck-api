require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @attributes = {
      name: "Katherine Johnson",
      username: "katherine",
      email: "katherine@example.com",
      password: "orbital1962",
      password_confirmation: "orbital1962"
    }
  end

  test "should get index" do
    get users_url
    assert_response :success
  end

  test "should get new" do
    get new_user_url
    assert_response :success
  end

  test "should create user" do
    assert_difference("User.count") do
      post users_url, params: { user: @attributes }
    end

    assert_redirected_to user_url(User.last)
    assert User.last.valid_password?("orbital1962")
  end

  test "should not create user without a password" do
    assert_no_difference("User.count") do
      post users_url, params: { user: @attributes.except(:password, :password_confirmation) }
    end

    assert_response :unprocessable_content
  end

  test "should show user" do
    get user_url(@user)
    assert_response :success
  end

  test "should not expose the password hash in the JSON representation" do
    get user_url(@user, format: :json)
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal @user.username, body["username"]
    assert_not_includes body.keys, "encrypted_password"
  end

  test "should get edit" do
    get edit_user_url(@user)
    assert_response :success
  end

  test "should update user" do
    patch user_url(@user), params: { user: { name: "Ada King" } }
    assert_redirected_to user_url(@user)
    assert_equal "Ada King", @user.reload.name
  end

  test "should update the password when one is supplied" do
    patch user_url(@user), params: { user: { password: "analytical", password_confirmation: "analytical" } }
    assert_redirected_to user_url(@user)
    assert @user.reload.valid_password?("analytical")
  end

  test "should keep the existing password when the field is left blank" do
    before = @user.encrypted_password

    patch user_url(@user), params: { user: { name: "Ada King", password: "", password_confirmation: "" } }

    assert_redirected_to user_url(@user)
    assert_equal before, @user.reload.encrypted_password
    assert @user.valid_password?("password")
  end

  test "should destroy user" do
    assert_difference("User.count", -1) do
      delete user_url(@user)
    end

    assert_redirected_to users_url
  end
end
