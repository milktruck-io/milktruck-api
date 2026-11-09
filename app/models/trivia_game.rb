# The game show itself. There is only ever one: `TriviaGame.current` finds it or
# creates it, so neither the host nor the players ever have to make a game first.
#
# The questions themselves live in the frontend (milktruck-web
# app/trivia/questions.ts) so they can be edited by hand without a deploy here.
# This side only tracks where in the running order we are and what each player
# tapped; the frontend knows which choice was correct and does the scoring.
class TriviaGame < ApplicationRecord
  PHASES = %w[ lobby question reveal results superlatives ].freeze

  # Entering this exact name on the join screen makes you the host. It is the
  # only admin credential there is, and no other name grants it.
  ADMIN_NAME = "milktruck gamemaster".freeze

  # Handed back on a successful admin join and sent on every host request.
  ADMIN_TOKEN = "milktruck-gamemaster-2026".freeze

  has_many :players, class_name: "TriviaPlayer", dependent: :destroy

  validates :phase, inclusion: { in: PHASES }

  def self.current
    first || create!
  end

  def self.admin_name?(name)
    name.to_s.strip.downcase == ADMIN_NAME
  end

  def answers
    TriviaAnswer.where(trivia_player_id: players.select(:id))
  end

  def current_answers
    answers.where(question_index: question_index)
  end

  # Host actions. `question_count` comes from the frontend so the running order
  # stays editable there: the host tells us how many questions the deck has.
  def start!(question_count)
    return if question_count.to_i.zero?
    update!(phase: "question", question_index: 0)
  end

  def reveal!
    update!(phase: "reveal") if phase == "question"
  end

  def next_question!(question_count)
    return unless phase == "reveal"

    if question_index + 1 >= question_count.to_i
      update!(phase: "results")
    else
      update!(phase: "question", question_index: question_index + 1)
    end
  end

  def show_results!
    update!(phase: "results")
  end

  def show_superlatives!
    update!(phase: "superlatives")
  end

  # Back to the lobby with the same players, answers wiped. Used if the show has
  # to be restarted on the night — nobody has to rejoin.
  def restart!
    answers.destroy_all
    update!(phase: "lobby", question_index: -1)
  end

  # Everything gone: players as well as answers. This is the one to use after a
  # test run, so no rehearsal names are left on the board.
  def clear!
    players.destroy_all
    update!(phase: "lobby", question_index: -1)
  end
end
