class AddSubjectCategoryToTriviaPlayers < ActiveRecord::Migration[8.1]
  def change
    # The category this player is the subject of — "sam" for Sam, "pete" for
    # Peter. They already know those answers, so the frontend scores that
    # category for them off the room average instead of their own taps.
    #
    # Just an opaque label here: the category ids live in the frontend
    # (app/trivia/questions.ts), same as the questions themselves.
    add_column :trivia_players, :subject_category, :string
  end
end
