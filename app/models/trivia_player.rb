# A player, identified by nothing but the name they typed. No passwords: the
# game is a one-night party piece and is deleted afterwards.
class TriviaPlayer < ApplicationRecord
  belongs_to :trivia_game
  has_many :answers, class_name: "TriviaAnswer", dependent: :destroy

  validates :name, presence: true,
                   length: { maximum: 16 },
                   uniqueness: { scope: :trivia_game_id, case_sensitive: false }

  before_validation { self.name = name.to_s.strip.gsub(/\s+/, " ") }

  # Blank and nil mean the same thing: this player is nobody's subject.
  before_validation { self.subject_category = subject_category.presence }
end
