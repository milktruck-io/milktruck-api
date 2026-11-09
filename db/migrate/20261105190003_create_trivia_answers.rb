class CreateTriviaAnswers < ActiveRecord::Migration[8.1]
  def change
    create_table :trivia_answers do |t|
      t.references :trivia_player, null: false, foreign_key: true
      t.integer :question_index, null: false
      t.integer :choice, null: false
      t.timestamps
    end

    # A player answers each question once, and once only.
    add_index :trivia_answers, [ :trivia_player_id, :question_index ], unique: true
  end
end
