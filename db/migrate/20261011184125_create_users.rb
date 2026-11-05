class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :username, null: false

      ## Devise :database_authenticatable
      # encrypted_password holds the bcrypt hash; the cost comes from
      # Devise.stretches (config/initializers/devise.rb).
      t.string :email, null: false
      t.string :encrypted_password, null: false

      ## Devise :recoverable
      t.string :reset_password_token
      t.datetime :reset_password_sent_at

      ## Devise :rememberable
      t.datetime :remember_created_at

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :username, unique: true
    add_index :users, :reset_password_token, unique: true
  end
end
