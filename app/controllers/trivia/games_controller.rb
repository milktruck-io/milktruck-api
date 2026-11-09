module Trivia
  class GamesController < BaseController
    before_action :require_admin!, only: %i[ advance kick set_subject ]

    # POST /trivia/join { name }
    # The only credential in the game: type the host's name and you are the
    # host, type anything else and you are a player.
    def join
      name = params[:name].to_s.strip

      if name.blank?
        return render json: { error: "Pick a name" }, status: :unprocessable_content
      end

      if TriviaGame.admin_name?(name)
        return render json: { admin: true, admin_token: TriviaGame::ADMIN_TOKEN, state: state_payload(nil, true) }
      end

      # The host console asks with host: true. A wrong phrase there is a failed
      # sign-in, not a new player — otherwise a typo on the console leaves a
      # stray name sitting on the board.
      if params[:host].present?
        return render json: { error: "That's not the host" }, status: :forbidden
      end

      # Rejoining with the same name picks the existing player back up, so
      # anyone who closes the tab or gets kicked can walk straight back in.
      player = game.players.find_by("LOWER(name) = ?", name.downcase) ||
               game.players.new(name: name)

      if player.persisted? || player.save
        render json: { admin: false, player: { id: player.id, name: player.name }, state: state_payload(player, false) }
      else
        render json: { error: player.errors.full_messages.to_sentence }, status: :unprocessable_content
      end
    end

    # GET /trivia/state?player_id=&admin_token=
    # Polled by every screen; the single source of truth for what to show.
    def state
      render json: state_payload(find_player, admin?)
    end

    # POST /trivia/answer { player_id, question_index, choice }
    # Only accepted while the question is live and only once per question, so a
    # player cannot change their mind after the reveal.
    def answer
      player = find_player
      return render json: { error: "Not in this game" }, status: :not_found if player.nil?

      if game.phase != "question" || params[:question_index].to_i != game.question_index
        return render json: { error: "That question is closed" }.merge(state_payload(player, false)), status: :conflict
      end

      TriviaAnswer.create(trivia_player: player, question_index: game.question_index, choice: params[:choice].to_i)

      render json: state_payload(player, false)
    end

    # PATCH /trivia/players/:id/name { name }
    # Fixing a typo, or putting the right name on a seat mid-show. The player
    # keeps their seat and every answer they have given — only the label
    # changes, and it changes on everyone else's screen on their next poll.
    def rename
      player = find_player_by_id(params[:id])
      return render json: { error: "Not in this game" }, status: :not_found if player.nil?

      name = params[:name].to_s.strip

      # The host name is a credential, not a name anyone can wear.
      if TriviaGame.admin_name?(name)
        return render json: { error: "That name is reserved" }, status: :unprocessable_content
      end

      if player.update(name: name)
        render json: state_payload(player, admin?)
      else
        render json: { error: player.errors.full_messages.to_sentence }, status: :unprocessable_content
      end
    end

    # PATCH /trivia/players/:id/subject { category }
    # Host only. Flags a player as the subject of a category — Sam for the Sam
    # questions, Peter for his. They can still tap an answer and you still see
    # it, but the frontend scores that category off the room average instead,
    # so knowing their own answers neither helps nor hurts them. Send a blank
    # category to clear the flag.
    def set_subject
      player = find_player_by_id(params[:id])
      return render json: { error: "Not in this game" }, status: :not_found if player.nil?

      player.update!(subject_category: params[:category])
      render json: state_payload(nil, true)
    end

    # POST /trivia/advance { step, question_count }
    # Every host control in one place. `question_count` travels with the
    # request because the deck lives in the frontend.
    def advance
      count = params[:question_count].to_i

      case params[:step]
      when "start" then game.start!(count)
      when "reveal" then game.reveal!
      when "next" then game.next_question!(count)
      when "results" then game.show_results!
      when "superlatives" then game.show_superlatives!
      when "restart" then game.restart!
      when "clear" then game.clear!
      else return render json: { error: "Unknown step" }, status: :unprocessable_content
      end

      render json: state_payload(nil, true)
    end

    # DELETE /trivia/players/:id
    # The escape hatch for the night: drop a player who is stuck or duplicated.
    def kick
      game.players.find_by(id: params[:id])&.destroy
      render json: state_payload(nil, true)
    end

    private

      def find_player
        find_player_by_id(params[:player_id])
      end

      def find_player_by_id(id)
        return nil if id.blank?
        game.players.find_by(id: id)
      end

      def state_payload(player, is_admin)
        players = game.players.order(:created_at).to_a
        all = game.answers.order(:question_index).to_a
        current = all.select { |a| a.question_index == game.question_index }

        # Guesses stay sealed until the host reveals them. The host always sees
        # them — that is the whole point of the admin screen.
        show_choices = is_admin || %w[ reveal results superlatives ].include?(game.phase)
        show_all = is_admin || %w[ results superlatives ].include?(game.phase)

        payload = {
          phase: game.phase,
          question_index: game.question_index,
          is_admin: is_admin,
          players: players.map { |p| { id: p.id, name: p.name, subject_category: p.subject_category } },
          answered_player_ids: current.map(&:trivia_player_id),
          choices: show_choices ? current.index_by { |a| a.trivia_player_id.to_s }.transform_values(&:choice) : {},
          all_answers: show_all ? all.map { |a| { player_id: a.trivia_player_id, question_index: a.question_index, choice: a.choice } } : nil
        }

        if player
          payload[:me] = {
            id: player.id,
            name: player.name,
            choices: player.answers.index_by { |a| a.question_index.to_s }.transform_values(&:choice)
          }
        elsif params[:player_id].present? && !is_admin
          # The player id we were given no longer exists: they were kicked, or
          # the game was wiped. The frontend sends them back to the join screen.
          payload[:removed] = true
        end

        payload
      end
  end
end
