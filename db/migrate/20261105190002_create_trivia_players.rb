class CreateTriviaPlayers < ActiveRecord::Migration[8.1]
  def change
    create_table :trivia_players do |t|
      t.references :trivia_game, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end

    add_index :trivia_players, [ :trivia_game_id, :name ], unique: true
  end
end
