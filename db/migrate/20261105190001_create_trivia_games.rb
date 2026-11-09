class CreateTriviaGames < ActiveRecord::Migration[8.1]
  def change
    create_table :trivia_games do |t|
      # lobby | question | reveal | results | superlatives
      t.string :phase, null: false, default: "lobby"
      # index into the frontend QUESTIONS array; -1 before the show starts
      t.integer :question_index, null: false, default: -1
      t.timestamps
    end
  end
end
