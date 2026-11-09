# One tap: which question, which choice index (0-based, matching the `choices`
# array in the frontend's questions.ts). Whether it was right is the frontend's
# business.
class TriviaAnswer < ApplicationRecord
  belongs_to :trivia_player

  validates :question_index, presence: true
  validates :choice, presence: true
  validates :trivia_player_id, uniqueness: { scope: :question_index }
end
