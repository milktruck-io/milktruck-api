# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Trivia game show (temporary)

Backs the Kahoot-style game at `milktruck-web/app/trivia` — delete both when
presentation night is over (`trivia_games`, `trivia_players`, `trivia_answers`).

It stores the phase, the players, and which choice index each player tapped.
It does **not** know the questions or the right answers: those live in the
frontend (`app/trivia/questions.ts`) so they can be edited by hand without a
deploy here, and the frontend does the scoring.

Everything is plain JSON under `/trivia`, CORS wide open, no CSRF, no Devise —
see `app/controllers/trivia/`.

| Endpoint | Does |
| --- | --- |
| `POST /trivia/join` | `{name}` → a player, or the host if the name matches `TriviaGame::ADMIN_NAME` |
| `GET /trivia/state` | the whole game, as the caller is allowed to see it (`player_id`, or the host token) |
| `POST /trivia/answer` | one tap: `{player_id, question_index, choice}` |
| `POST /trivia/advance` | host only: `{step, question_count}` where step is start / reveal / next / results / superlatives / restart (keeps players) / clear (wipes them too) |
| `PATCH /trivia/players/:id/name` | rename in place — the seat, the score and the answers all stay |
| `PATCH /trivia/players/:id/subject` | host only: flag this player as the subject of a category (blank clears it) |
| `DELETE /trivia/players/:id` | host only: kick someone who gets stuck |

The only credential is the host name in `TriviaGame::ADMIN_NAME`; a successful
host join hands back `ADMIN_TOKEN`, which host requests send as
`X-Admin-Token`. Players have no credentials at all — by design, since the
whole thing is thrown away afterwards. Guesses are withheld from players until
the host reveals them.
