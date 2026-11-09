require "test_helper"

class Trivia::GamesControllerTest < ActionDispatch::IntegrationTest
  ADMIN_HEADERS = { "X-Admin-Token" => TriviaGame::ADMIN_TOKEN }.freeze

  test "joining with a name creates a player and rejoining returns the same one" do
    assert_difference("TriviaPlayer.count", 1) do
      post trivia_join_url, params: { name: "Jack" }
    end
    assert_response :success
    first = response.parsed_body

    assert_equal false, first["admin"]
    assert_equal "Jack", first["player"]["name"]

    # Same name, different case: the player walks back into their own seat
    # rather than getting a duplicate.
    assert_no_difference("TriviaPlayer.count") do
      post trivia_join_url, params: { name: "  jack " }
    end
    assert_equal first["player"]["id"], response.parsed_body["player"]["id"]
  end

  test "a player name longer than the box allows is rejected with a readable error" do
    post trivia_join_url, params: { name: "a name far too long to fit on a chip" }
    assert_response :unprocessable_content
    assert_match(/too long/, response.parsed_body["error"])
  end

  test "only the whole host phrase grants the console" do
    # The join box on /game has to allow at least this many characters, or the
    # host types the phrase, gets truncated, and silently joins as a player.
    assert_operator TriviaGame::ADMIN_NAME.length, :<=, 32, "the host phrase must fit in the join box"

    # Rejected outright (too long to be a player name) or admitted as a plain
    # player — either way, not the host.
    post trivia_join_url, params: { name: TriviaGame::ADMIN_NAME.chop }
    refute response.parsed_body["admin"], "a partial phrase must not grant the console"
  end

  test "joining with a blank name is rejected" do
    post trivia_join_url, params: { name: "   " }
    assert_response :unprocessable_content
  end

  test "the hardcoded host name is the only way to become admin" do
    post trivia_join_url, params: { name: "Milktruck Gamemaster" }
    assert_response :success
    assert_equal true, response.parsed_body["admin"]
    assert_equal TriviaGame::ADMIN_TOKEN, response.parsed_body["admin_token"]
    # The host is not a player.
    assert_equal 0, TriviaPlayer.count

    post trivia_join_url, params: { name: "the gamemaster" }
    assert_equal false, response.parsed_body["admin"]
    assert_nil response.parsed_body["admin_token"]
  end

  test "a wrong phrase on the host console signs nobody in and creates nobody" do
    assert_no_difference("TriviaPlayer.count") do
      post trivia_join_url, params: { name: "not the host", host: true }
    end
    assert_response :forbidden
    assert_equal "That's not the host", response.parsed_body["error"]

    # The real phrase still works through the same door.
    post trivia_join_url, params: { name: TriviaGame::ADMIN_NAME, host: true }
    assert_response :success
    assert_equal true, response.parsed_body["admin"]
    assert_equal 0, TriviaPlayer.count
  end

  test "host controls walk the game through every phase" do
    player = join("Jack")

    post trivia_advance_url, params: { step: "start", question_count: 2 }, headers: ADMIN_HEADERS
    assert_equal "question", response.parsed_body["phase"]
    assert_equal 0, response.parsed_body["question_index"]

    post trivia_advance_url, params: { step: "reveal" }, headers: ADMIN_HEADERS
    assert_equal "reveal", response.parsed_body["phase"]

    post trivia_advance_url, params: { step: "next", question_count: 2 }, headers: ADMIN_HEADERS
    assert_equal "question", response.parsed_body["phase"]
    assert_equal 1, response.parsed_body["question_index"]

    # The last question runs out into the results rather than a question 3.
    post trivia_advance_url, params: { step: "reveal" }, headers: ADMIN_HEADERS
    post trivia_advance_url, params: { step: "next", question_count: 2 }, headers: ADMIN_HEADERS
    assert_equal "results", response.parsed_body["phase"]

    post trivia_advance_url, params: { step: "superlatives" }, headers: ADMIN_HEADERS
    assert_equal "superlatives", response.parsed_body["phase"]

    answer(player, 0, 1) # ignored: the question is long closed
    assert_response :conflict
  end

  test "players answer once and only while the question is live" do
    player = join("Jack")

    answer(player, 0, 2)
    assert_response :conflict, "no question is live yet"

    start_question(0, question_count: 2)

    assert_difference("TriviaAnswer.count", 1) do
      answer(player, 0, 2)
      assert_response :success
    end

    # A second tap does not overwrite the first.
    assert_no_difference("TriviaAnswer.count") do
      answer(player, 0, 3)
    end
    assert_equal 2, TriviaAnswer.last.choice

    # Nor does answering a question that is not the one on screen.
    assert_no_difference("TriviaAnswer.count") do
      answer(player, 1, 0)
      assert_response :conflict
    end

    post trivia_advance_url, params: { step: "reveal" }, headers: ADMIN_HEADERS
    assert_no_difference("TriviaAnswer.count") do
      answer(player, 0, 1)
      assert_response :conflict
    end
  end

  test "guesses stay sealed from players until the reveal but never from the host" do
    jack = join("Jack")
    sam = join("Sam")
    start_question(0, question_count: 1)
    answer(jack, 0, 2)

    get trivia_state_url, params: { player_id: sam["id"] }
    sealed = response.parsed_body
    assert_equal [ jack["id"] ], sealed["answered_player_ids"], "Sam can see that Jack is in"
    assert_empty sealed["choices"], "but not what Jack picked"
    assert_nil sealed["all_answers"]

    get trivia_state_url, headers: ADMIN_HEADERS
    assert_equal({ jack["id"].to_s => 2 }, response.parsed_body["choices"])

    post trivia_advance_url, params: { step: "reveal" }, headers: ADMIN_HEADERS
    get trivia_state_url, params: { player_id: sam["id"] }
    assert_equal({ jack["id"].to_s => 2 }, response.parsed_body["choices"])
  end

  test "every answer is published once the game reaches the results" do
    jack = join("Jack")
    start_question(0, question_count: 1)
    answer(jack, 0, 3)
    post trivia_advance_url, params: { step: "results" }, headers: ADMIN_HEADERS

    get trivia_state_url, params: { player_id: jack["id"] }
    all = response.parsed_body["all_answers"]
    assert_equal [ { "player_id" => jack["id"], "question_index" => 0, "choice" => 3 } ], all
  end

  test "a player's own answers travel with their state" do
    jack = join("Jack")
    start_question(0, question_count: 2)
    answer(jack, 0, 1)

    get trivia_state_url, params: { player_id: jack["id"] }
    assert_equal({ "0" => 1 }, response.parsed_body["me"]["choices"])
  end

  test "renaming keeps the seat, the score and every answer" do
    jack = join("Jack")
    start_question(0, question_count: 2)
    answer(jack, 0, 1)

    patch trivia_player_name_url(jack["id"]), params: { name: "Jack C" }
    assert_response :success
    assert_equal "Jack C", response.parsed_body["me"]["name"]
    assert_equal({ "0" => 1 }, response.parsed_body["me"]["choices"], "answers survive the rename")
    assert_equal jack["id"], response.parsed_body["me"]["id"], "same seat"
    assert_equal 1, TriviaPlayer.count

    # Everyone else sees the new name on their next poll.
    get trivia_state_url
    assert_equal [ "Jack C" ], response.parsed_body["players"].map { |p| p["name"] }
  end

  test "a rename has to clear the same bar as a join" do
    jack = join("Jack")
    join("Sam")

    patch trivia_player_name_url(jack["id"]), params: { name: "Sam" }
    assert_response :unprocessable_content
    assert_match(/taken/i, response.parsed_body["error"])

    patch trivia_player_name_url(jack["id"]), params: { name: "   " }
    assert_response :unprocessable_content

    # The host name is a credential, not a name to wear.
    patch trivia_player_name_url(jack["id"]), params: { name: TriviaGame::ADMIN_NAME }
    assert_response :unprocessable_content
    assert_equal "That name is reserved", response.parsed_body["error"]

    patch trivia_player_name_url(99_999), params: { name: "Ghost" }
    assert_response :not_found

    assert_equal "Jack", TriviaPlayer.find(jack["id"]).name
  end

  test "renaming to your own name is a no-op, not a duplicate error" do
    jack = join("Jack")
    patch trivia_player_name_url(jack["id"]), params: { name: "Jack" }
    assert_response :success
    assert_equal "Jack", response.parsed_body["me"]["name"]
  end

  test "switching player leaves the seat on the board to be picked up again" do
    jack = join("Jack")
    start_question(0, question_count: 1)
    answer(jack, 0, 2)

    # "Switch player" is local to the phone — nothing is called, so the seat
    # and its answers stay put and the same name walks back into them.
    post trivia_join_url, params: { name: "Jack" }
    assert_equal jack["id"], response.parsed_body["player"]["id"]
    assert_equal({ "0" => 2 }, response.parsed_body["state"]["me"]["choices"])
  end

  test "the host can flag a player as a category subject and clear it again" do
    jack = join("Jack")

    patch trivia_player_subject_url(jack["id"]), params: { category: "sam" }, headers: ADMIN_HEADERS
    assert_response :success
    assert_equal "sam", response.parsed_body["players"].first["subject_category"]

    # Everyone's state carries the flag, so every screen can score the same way.
    get trivia_state_url, params: { player_id: jack["id"] }
    assert_equal "sam", response.parsed_body["players"].first["subject_category"]

    patch trivia_player_subject_url(jack["id"]), params: { category: "" }, headers: ADMIN_HEADERS
    assert_nil response.parsed_body["players"].first["subject_category"]
  end

  test "a subject still answers normally — the flag only changes the scoring" do
    jack = join("Jack")
    patch trivia_player_subject_url(jack["id"]), params: { category: "sam" }, headers: ADMIN_HEADERS
    start_question(0, question_count: 4)

    assert_difference("TriviaAnswer.count", 1) do
      answer(jack, 0, 2)
      assert_response :success
    end

    # The host sees the guess like anyone else's.
    get trivia_state_url, headers: ADMIN_HEADERS
    assert_equal({ jack["id"].to_s => 2 }, response.parsed_body["choices"])
  end

  test "only the host can flag a subject" do
    jack = join("Jack")

    patch trivia_player_subject_url(jack["id"]), params: { category: "sam" }
    assert_response :forbidden
    assert_nil TriviaPlayer.find(jack["id"]).subject_category

    patch trivia_player_subject_url(99_999), params: { category: "sam" }, headers: ADMIN_HEADERS
    assert_response :not_found
  end

  test "renaming keeps a subject flag" do
    jack = join("Jack")
    patch trivia_player_subject_url(jack["id"]), params: { category: "pete" }, headers: ADMIN_HEADERS
    patch trivia_player_name_url(jack["id"]), params: { name: "Peter" }

    assert_response :success
    assert_equal "pete", TriviaPlayer.find(jack["id"]).subject_category
  end

  test "kicking removes the player and their answers, and they can rejoin" do
    jack = join("Jack")
    start_question(0, question_count: 1)
    answer(jack, 0, 1)

    assert_difference("TriviaAnswer.count", -1) do
      delete trivia_player_url(jack["id"]), headers: ADMIN_HEADERS
    end
    assert_response :success
    assert_empty response.parsed_body["players"]

    # The kicked phone finds out on its next poll.
    get trivia_state_url, params: { player_id: jack["id"] }
    assert_equal true, response.parsed_body["removed"]
    assert_nil response.parsed_body["me"]

    post trivia_join_url, params: { name: "Jack" }
    assert_response :success
  end

  test "restarting clears answers but keeps everyone in the room" do
    jack = join("Jack")
    start_question(0, question_count: 1)
    answer(jack, 0, 1)

    post trivia_advance_url, params: { step: "restart" }, headers: ADMIN_HEADERS
    assert_equal "lobby", response.parsed_body["phase"]
    assert_equal(-1, response.parsed_body["question_index"])
    assert_equal 1, response.parsed_body["players"].length
    assert_equal 0, TriviaAnswer.count
  end

  test "clearing the room removes the players too, for a clean start after a test run" do
    jack = join("Jack")
    start_question(0, question_count: 1)
    answer(jack, 0, 1)

    post trivia_advance_url, params: { step: "clear" }, headers: ADMIN_HEADERS
    assert_equal "lobby", response.parsed_body["phase"]
    assert_equal(-1, response.parsed_body["question_index"])
    assert_empty response.parsed_body["players"]
    assert_equal 0, TriviaPlayer.count
    assert_equal 0, TriviaAnswer.count

    # The rehearsal phones are sent back to the join screen.
    get trivia_state_url, params: { player_id: jack["id"] }
    assert_equal true, response.parsed_body["removed"]
  end

  test "host-only endpoints reject anyone without the token" do
    jack = join("Jack")

    post trivia_advance_url, params: { step: "start", question_count: 1 }
    assert_response :forbidden

    post trivia_advance_url, params: { step: "start", question_count: 1 }, headers: { "X-Admin-Token" => "guess" }
    assert_response :forbidden

    delete trivia_player_url(jack["id"])
    assert_response :forbidden
    assert_equal 1, TriviaPlayer.count

    post trivia_advance_url, params: { step: "burn it down" }, headers: ADMIN_HEADERS
    assert_response :unprocessable_content
  end

  test "cross-origin requests get the headers they need" do
    options trivia_state_url
    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]

    get trivia_state_url
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  private

    def join(name)
      post trivia_join_url, params: { name: name }
      response.parsed_body["player"]
    end

    def start_question(index, question_count:)
      post trivia_advance_url, params: { step: "start", question_count: question_count }, headers: ADMIN_HEADERS
      index.times do
        post trivia_advance_url, params: { step: "reveal" }, headers: ADMIN_HEADERS
        post trivia_advance_url, params: { step: "next", question_count: question_count }, headers: ADMIN_HEADERS
      end
    end

    def answer(player, question_index, choice)
      post trivia_answer_url, params: { player_id: player["id"], question_index: question_index, choice: choice }
    end
end
