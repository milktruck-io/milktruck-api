# Web Development Bible

A from-first-principles reference for how a decoupled web app works end to end: a Rails JSON API backend, a React (React Router v7) SSR frontend, how they talk to each other, and how the whole thing gets a real domain and lives on a host like Fly.io.

Everything here is grounded in two real, currently-running codebases:

- **`secret-bunker`** — the Rails API backend (Ruby 3.3.11, Rails 8.1). Deployed as Fly apps `secret-bunker` (prod) / `secret-bunker-dev` (dev).
- **`scholars-rock`** — the React Router v7 SSR frontend (Node 20, React 19, TypeScript). Deployed as Fly apps `scholars-rock` (prod) / `scholars-rock-dev` (dev).

Production domain: `triad.tech` (frontend) talking to `secret-bunker.fly.dev` (backend). Dev: `dev.triad.tech` talking to `dev.api.triad.tech`.

---

## 1. The big picture

```
 Browser                     Frontend (scholars-rock)              Backend (secret-bunker)
┌──────────┐   HTML/JS      ┌───────────────────────────┐  JSON    ┌──────────────────────┐
│  User's  │ ◄────────────► │ React Router v7 (SSR)     │ ◄──────► │ Rails 8, API-only     │
│  browser │  triad.tech     │ Node server on Fly        │  https   │ controllers,          │
│          │                │ fetches Rails server-side  │          │ Postgres DB           │
└──────────┘                └───────────────────────────┘          └──────────────────────┘
     ▲                              │                                       ▲
     └── never talks to Rails directly for page loads ─────────────────────┘
              (client-side XHR only happens for a few JS-driven bits, e.g. uploads)
```

Two independent git repos, two independent Fly.io apps, two independent deploy pipelines. They agree on a contract: URLs, JSON shapes, and a bearer token. That's the entire coupling — there's no shared code, shared package, or shared repo.

This is the standard **decoupled/headless** architecture: the Rails app never renders HTML for end users, it only returns JSON. The React app never talks to Postgres, it only calls Rails over HTTP.

---

## 2. The backend: Rails as a pure JSON API

### 2.1 Shape of the app

`secret-bunker` is *not* Rails' `--api` mode globally, but it's architected that way per-namespace:

```ruby
# app/controllers/api/application_controller.rb
class Api::ApplicationController < ActionController::API
  # no sessions, no cookies, no view rendering, no CSRF middleware at all
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  # full stack — only used for Devise's session controller and OAuth/consent-adjacent controllers
end
```

Everything under `/api/*` inherits from `ActionController::API`, which strips out the browser-oriented middleware (cookies, CSRF, flash) that a full `ActionController::Base` app carries. This is the key decision that makes the backend a "pure" API: it fundamentally can't render a login form or set a session cookie for `/api/*` requests — it can only take JSON in and put JSON out.

### 2.2 Routing convention

```ruby
# config/routes.rb
namespace :api, defaults: { format: :json } do
  resources :clients,      only: [:index, :show, :create, :update, :destroy]
  resources :projects,     only: [:index, :show, :create, :update, :destroy]
  resources :job_postings, only: [:index, :show, :create, :update, :destroy]
  resources :users, only: [:index, :show], param: :username

  patch "users/me", to: "users#update"
  # ...

  match "*path", to: ->(env) { [404, { "Content-Type" => "application/json" }, ['{"error":"Not found"}']] }, via: :all
end
```

Notes worth internalizing for any Rails API:

- `namespace :api, defaults: { format: :json }` means you never need `.json` suffixes in the URL and controllers don't need `respond_to`.
- No `/api/v1` here — this API is flat. That's a legitimate choice for a small internal API with one consumer; version your routes (`namespace :v1`) the moment you have external/other consumers you can't force-upgrade in lockstep.
- The catch-all `match "*path" ... via: :all` at the bottom of the namespace returns a clean JSON 404 instead of Rails' default HTML error page — important because a JS client parsing `response.json()` will choke on an HTML body.
- `param: :username` on `resources :users` changes the implicit `:id` segment to `:username` — so `GET /api/users/:username` instead of `/api/users/:id`. Use this whenever the natural lookup key isn't the numeric PK.

### 2.3 Authentication: Devise + JWT, not sessions

The backend issues a **JWT bearer token**, not a session cookie — because the two apps live on different origins/subdomains and a cross-origin cookie is exactly the kind of thing browsers are increasingly hostile to (SameSite, third-party cookie blocking). A bearer token sidesteps all of that.

```ruby
# config/initializers/devise.rb
config.jwt do |jwt|
  jwt.secret = ENV["DEVISE_JWT_SECRET_KEY"]
  jwt.dispatch_requests   = [["POST", %r{^/api/auth/token$}], ["POST", %r{^/api/auth/google$}]]
  jwt.revocation_requests = [["DELETE", %r{^/api/auth/token$}]]
  jwt.expiration_time = 7.days.to_i
end
```

`devise-jwt`'s dispatch middleware watches for successful requests to the listed routes and automatically stamps a `Authorization: Bearer <jwt>` header onto the *response* — the controller just needs to `sign_in` the user; it doesn't build the JWT itself.

```ruby
# app/controllers/api/auth/sessions_controller.rb (abbreviated)
class Api::Auth::SessionsController < Devise::SessionsController
  skip_before_action :verify_authenticity_token, if: :json_request?
  # devise-jwt handles the token; this controller just needs to succeed at sign_in
end
```

```ruby
# app/views/api/auth/sessions/create.json.jbuilder
json.user do
  json.id @user.id
  json.email @user.email
  json.name @user.name
  json.username @user.username
  json.role @user.role
  json.permissions @user.permissions
end
```

Enforcing auth on a protected endpoint:

```ruby
# app/controllers/api/application_controller.rb
def require_permission!(permission)
  authenticate_user!
  render json: { error: "Forbidden" }, status: :forbidden unless current_user&.has_permission?(permission)
  # NOTE: this does not `return` — every caller must add `return if performed?` after calling it,
  # otherwise the action body keeps executing after a 403 has already been rendered.
end
```

```ruby
class Api::JobPostingsController < Api::ApplicationController
  before_action -> { require_permission!(Permission::CREATE_JOB_LISTING) }, only: [:create]
end
```

Revocation strategy is `Devise::JWT::RevocationStrategies::Null` — meaning "logout" is purely advisory (the frontend forgets the token), the token itself stays valid server-side until it naturally expires in 7 days. Fine for a low-stakes internal tool; if you need real server-side revocation (e.g. "kill this session right now"), use the `JTIMatcher` strategy instead, which tracks a `jti` column per user and invalidates on rotation.

### 2.4 Google Workspace–restricted OAuth login

```ruby
# app/controllers/api/auth/google_auth_controller.rb (concept)
def create
  payload = GoogleTokenVerification.verify(params[:id_token]) # hits Google's public certs, checks aud/exp/sig
  raise Unauthorized unless payload["email_verified"]
  raise Unauthorized unless payload["email"].end_with?("@#{ENV.fetch("GOOGLE_WORKSPACE_DOMAIN", "triad.tech")}")

  user = User.find_or_create_by!(email: payload["email"])
  sign_in(user)   # devise-jwt dispatch middleware attaches the Authorization header, same as password login
end
```

**Security detail worth remembering**: the domain check is against the *verified* `email` claim from Google's signed ID token, not the `hd` (hosted domain) query param the client sends when *initiating* the OAuth flow. `hd` is just a UI hint to Google's login screen ("suggest this domain") — it is not attested and a client can send any value. Never gate access on `hd`; always re-check the final verified `email` server-side.

### 2.5 CORS — who's allowed to call this API from a browser

```ruby
# config/initializers/cors.rb
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "http://localhost:5371", "https://www.triad.tech", "https://triad.tech", "https://dev.triad.tech"
    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: ["Authorization"],   # so client-side JS can read the token off the response
      credentials: false           # bearer-token API — no cookies crossing origins, so this is correctly false
  end
end
```

Three things to internalize:

1. **CORS is a browser-enforced rule, not a server security boundary.** It only stops a *browser* from letting page JS read a cross-origin response; it does nothing to stop `curl`, Postman, or server-to-server calls (like the frontend's own SSR loaders, which run in Node and are unaffected by CORS entirely — see §4.1).
2. **`origins` is an explicit allowlist.** `localhost:5371` is in there specifically because that's the frontend's dev port (see §3.1) — if you change the frontend's dev port, this list goes stale silently (no CORS error appears until someone tries the actual login flow from a browser).
3. **`expose: ["Authorization"]`** matters because by default `fetch`/XHR can only read a small "safe list" of response headers cross-origin; `Authorization` isn't on that list unless the server explicitly exposes it. Miss this and login "works" (200 response) but the frontend silently can't extract the token.

### 2.6 Serialization: hand-built JSON, snake_case

No `ActiveModel::Serializer`, no GraphQL. Just `render json:` with hand-shaped hashes:

```ruby
# app/controllers/api/users_controller.rb
def index
  render json: users.map { |u|
    { username: u.username, name: u.name, title: u.title, role: u.role, avatar_url: avatar_url_for(u) }
  }
end
```

The contract with the frontend is implicit and textual: whatever keys appear in these hashes are what `jobs.server.ts`/`users.server.ts` on the frontend must know to read. There's no schema file, no OpenAPI spec, no generated types — **the two repos are kept in sync by hand**. This is the single biggest maintenance risk in a decoupled setup like this; see §6 for what to do about it.

### 2.7 Deployment shape

```dockerfile
# Dockerfile (secret-bunker)
FROM ruby:3.3.11-slim
EXPOSE 3000
ENTRYPOINT ["/rails/bin/docker-entrypoint"]   # runs `bin/rails db:prepare` before boot
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

```toml
# fly.toml (production app: secret-bunker)
app = "secret-bunker"
primary_region = "iad"
[env]
  FRONTEND_BASE_URL = "https://triad.tech"
[deploy]
  release_command = "bin/rails db:migrate"    # runs once per deploy, before the new machines take traffic
[http_service]
  internal_port = 3000
  force_https = true
  min_machines_running = 1
  [[http_service.checks]]
    path = "/up"                              # Rails' built-in health check route
```

`fly.development.toml` is the same shape for app `secret-bunker-dev`, with `FRONTEND_BASE_URL = "https://dev.triad.tech"` and `auto_stop_machines = "stop"` (scales to zero when idle — fine for a dev environment nobody's hitting at 3am).

Pipeline: GitHub Actions runs tests → on success, builds+pushes a Docker image → `flyctl deploy`. Branch `main` deploys to `secret-bunker`; branch `development` deploys to `secret-bunker-dev`. `[deploy].release_command` is the standard Rails-on-Fly pattern for running migrations safely: it runs in a one-off machine *before* the new release's machines start serving traffic, so you never serve requests against a not-yet-migrated schema.

---

## 3. The frontend: React Router v7 in SSR mode

### 3.1 Dev server and routing

```ts
// vite.config.ts
export default defineConfig({
  plugins: [tailwindcss(), reactRouter(), tsconfigPaths()],
  server: { host: true, port: 5371 },   // NOT the React Router default (5173)
});
```

Routes are declared centrally, not file-based:

```ts
// app/routes.ts
export default [
  index("routes/home.tsx"),
  route("careers", "routes/careers.tsx"),
  route("admin", "routes/admin.tsx"),
  route("admin/:name", "routes/admin.$name.tsx"),
  ...prefix("cork", [
    layout("routes/cork/layout.tsx", [ index("routes/cork/home.tsx"), route("clients", "routes/cork/clients.tsx") ]),
  ]),
  route("api/auth/google", "routes/api.auth.google.tsx"),   // the frontend has its OWN /api/* routes — these are
  route("oauth/authorize", "routes/oauth.authorize.tsx"),   // Node route handlers, not proxies to Rails
  route(":name", "routes/profile.$name.tsx"),               // catch-all profile slug — must avoid reserved names
  route("*", "routes/not-found.tsx"),
] satisfies RouteConfig;
```

Two easy-to-miss conventions:

- Adding a page means **both** creating the route module under `app/routes/` **and** registering it here — nothing is auto-discovered from the filesystem.
- The dynamic `:name` catch-all (used for public profile pages, `triad.tech/jsmith`) sits *after* every static top-level route in file terms but needs a `RESERVED_PROFILE_SLUGS` set in `profile.$name.tsx` so a real user can never register a username like `admin` or `careers` that would shadow (or be shadowed by) a real route.
- Note `app/routes/api.auth.google.tsx` and `app/routes/oauth.authorize.tsx` — the **frontend itself** exposes routes under `/api/*` and `/oauth/*`. These are not Rails proxies; they're regular React Router route modules whose `loader`/`action` run server-side in the Node process. Don't confuse "a URL path that starts with `/api`" with "goes to the Rails backend" — only `RAILS_API_URL + endpoint` calls (§4) actually leave this process.

### 3.2 Sessions live in an encrypted cookie, not localStorage

```ts
// app/lib/auth.server.ts
export const sessionStorage = createCookieSessionStorage({
  cookie: {
    name: "__session",
    httpOnly: true,
    sameSite: "lax",
    secrets: [SESSION_SECRET],
    secure: process.env.NODE_ENV === "production",
    maxAge: 60 * 60 * 24 * 30,   // 30 days — matches (exceeds) the 7-day Rails JWT expiry intentionally as a ceiling
  },
});
```

The JWT that Rails issues is stored **inside this cookie**, server-side only (`httpOnly: true` — client JS can never read it, closing off the most common XSS-token-theft vector). Every page load, a `loader` calls `requireAuth(request)`, which pulls the token out of the cookie and attaches it to the *server-side* fetch to Rails:

```ts
// app/lib/auth.server.ts
export async function requireAuth(request: Request) {
  const token = await getAuthToken(request);
  const user = await getUser(request);
  if (!token || !user) throw redirect("/login");
  return { token, user };
}
```

This is the architectural payoff of SSR here: the browser never sees the JWT at all. It only ever holds an encrypted, httpOnly session cookie scoped to `triad.tech`. The Node server is the only thing that ever puts `Authorization: Bearer <jwt>` on a wire, and it only does so talking to `RAILS_API_URL` — never back to the browser.

### 3.3 The server-only lib layer — the single seam between the two apps

```ts
// app/lib/api.server.ts
export async function authenticatedFetch<T>(endpoint: string, token: string, options: RequestInit = {}): Promise<T> {
  return apiFetch<T>(endpoint, options, token);
}

async function apiFetch<T>(endpoint: string, options: RequestInit, token?: string): Promise<T> {
  const headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
  const response = await fetch(`${RAILS_API_URL}${endpoint}`, {
    ...options, headers, signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`API request failed: ${response.status} - ${await response.text()}`);
  const text = await response.text();
  return text ? JSON.parse(text) : ({} as T);
}
```

Everything the frontend knows about Rails funnels through this one file (`publicFetch`, `authenticatedFetch`, `authenticatedUpload`). That centralization is what makes the CORS discussion in §2.5 almost moot for page loads: **`fetch` calls made inside a React Router `loader`/`action` run in the Node server process, not the browser** — so they are plain server-to-server HTTP calls, invisible to CORS entirely. CORS only starts to matter the moment a `*.client.tsx` component makes its *own* `fetch` directly from browser JS (e.g. a progress-tracked upload widget) — that's a real cross-origin browser request and needs the Rails allowlist in §2.5 to include the frontend's origin.

Domain wrappers sit on top, mapping Rails' snake_case field names to the frontend's camelCase conventions by hand (there's no codegen):

```ts
// pattern used in jobs.server.ts
function mapFromRails(raw: RailsJobPosting): JobPosting {
  return { id: raw.id, title: raw.title, createdAt: raw.created_at /* ... */ };
}
```

### 3.4 Deployment shape

```dockerfile
# Dockerfile (scholars-rock) — 4-stage build for a small final image
FROM node:20-alpine AS build-env
RUN npm run build          # react-router build → build/client (static assets) + build/server (SSR bundle)
FROM node:20-alpine
COPY --from=build-env /app/build /app/build
CMD ["npm", "run", "start"]  # react-router-serve ./build/server/index.js
```

```toml
# fly.toml (production app: scholars-rock)
app = "scholars-rock"
[env]
  RAILS_API_URL = "https://secret-bunker.fly.dev"   # ← the entire link between the two Fly apps is one env var
  APP_URL = "https://triad.tech"
[http_service]
  internal_port = 3000
```

That `RAILS_API_URL` line is worth staring at: **the only thing that wires these two independently-deployed services together at runtime is one environment variable pointing at the other app's Fly-issued hostname.** No shared VPC config, no service mesh, no hardcoded IP — just a URL. This is the essence of how independently deployable services integrate on Fly (or anywhere): a well-known origin, injected via config, not code.

---

## 4. How the two apps actually talk — full request walkthroughs

### 4.1 A normal page load (server-to-server, no CORS involved)

```
1. Browser: GET https://triad.tech/careers
2. Fly routes to a scholars-rock machine → Node process → React Router matches route("careers", ...)
3. That route's `loader(request)` runs on the server:
     const { token } = await requireAuth(request)                 // cookie → JWT, no network call
     const postings = await authenticatedFetch("/api/job_postings", token)
4. Node process makes a real HTTP request:
     GET https://secret-bunker.fly.dev/api/job_postings
     Authorization: Bearer eyJhbGciOi...
   (server-to-server — the browser is not involved in this hop at all, so CORS is irrelevant here)
5. Rails: Api::JobPostingsController#index → require_permission!(...) → render json: [...]
6. Node process receives JSON, the loader returns it, React Router renders HTML server-side
7. Browser receives a fully-rendered HTML page (SSR) — then hydrates for client-side interactivity
```

### 4.2 Login (password)

```
Browser → POST https://triad.tech/login (form submit, hits an `action` in login.tsx)
  Node → POST https://secret-bunker.fly.dev/api/auth/token   { user: { email, password } }
  Rails → Devise validates password → devise-jwt middleware stamps `Authorization: Bearer <jwt>`
        → jbuilder view returns { user: {...} }
  Node reads `response.headers.get("Authorization")`, strips "Bearer ", gets the raw JWT
  Node calls createUserSession(token, user, "/admin")
        → writes { token, user } into the encrypted __session cookie
        → Set-Cookie header on the redirect response
Browser stores the __session cookie (httpOnly — JS can't touch it) and follows the redirect
```

### 4.3 Login (Google Workspace SSO)

```
Browser → GET https://triad.tech/api/auth/google  (route in scholars-rock, NOT Rails)
  Node builds the Google consent URL itself, including hd=triad.tech as a UI hint, and 302s the browser to it
Browser → Google's own consent screen (accounts.google.com) — this hop is fully out of both apps' hands
Google → redirects browser back to https://triad.tech/api/auth/google/callback?code=...
  Node exchanges `code` for an `id_token` directly with Google (server-to-server, client_secret involved)
  Node → POST https://secret-bunker.fly.dev/api/auth/google  { id_token }
  Rails verifies the id_token's signature against Google's public certs, checks the *verified* email
        domain === triad.tech, find_or_create_by! the user, sign_in → JWT attached to response
  Node extracts the JWT the same way as password login, writes the session cookie, redirects to /admin
```

Three separate parties, three separate hops — worth keeping straight when debugging: (1) browser↔Google is Google's UI, (2) Node↔Google is a server-to-server token exchange using a client secret, (3) Node↔Rails is where your own trust boundary (the workspace-domain check) actually gets enforced.

### 4.4 The OAuth "consent screen" split (the DEV-36 work)

This is the one place where the two repos genuinely co-design a single feature, worth calling out because it's the most subtle integration in the whole system: secret-bunker acts as a Doorkeeper (OAuth 2.1 + PKCE) **authorization server** for third-party/MCP clients (e.g. Claude, Cursor), but it deliberately does **not** render the consent screen itself — it delegates that to the frontend.

```ruby
# secret-bunker: app/controllers/oauth/metadata_controller.rb
# advertises: authorization_endpoint: "#{FRONTEND_BASE_URL}/oauth/authorize"
```

```
1. Third-party client redirects the user's browser to https://triad.tech/oauth/authorize?client_id=...&code_challenge=...
2. scholars-rock's `oauth.authorize.tsx` route loader:
     GET https://secret-bunker.fly.dev/api/oauth/client?client_id=...
     → { name: "Claude Desktop", scopes: "mcp profile" }
   ...and renders a consent screen: "Claude Desktop wants to access your mcp, profile scopes. Allow?"
3. User (already authenticated via the __session cookie / JWT) clicks Allow.
   The route's `action` calls:
     POST https://secret-bunker.fly.dev/api/oauth/authorize   { client_id, redirect_uri, code_challenge, ... }
     Authorization: Bearer <the user's own JWT>
   Rails validates PKCE + redirect_uri, creates a Doorkeeper::AccessGrant, returns { code, state }
4. Node 302s the *original* third-party client's redirect_uri with that code
5. Third-party client exchanges `code` (+ PKCE verifier) for an access token directly against
   secret-bunker's Doorkeeper token endpoint — this last hop never touches scholars-rock at all
```

Why split it this way: Doorkeeper (a Ruby gem) has no concept of your brand's login UI or session cookie — it only knows how to mint/validate tokens. The frontend already owns "what does an authenticated triad.tech user see," so the consent *UI* naturally lives there, while the *authority* to grant access (validating the OAuth client, minting the grant) stays in the one place that owns the OAuth application registry: the backend. `FRONTEND_BASE_URL` (a Rails env var, set per Fly app — `https://triad.tech` prod / `https://dev.triad.tech` dev) is what tells the backend which frontend origin currently owns that UI.

---

## 5. URLs, environments, and domains at a glance

| Environment | Frontend URL | Backend URL | Frontend Fly app | Backend Fly app |
|---|---|---|---|---|
| Local dev | `http://localhost:5371` | `http://localhost:3000` | — | — |
| Development (deployed) | `https://dev.triad.tech` | `https://dev.api.triad.tech` | `scholars-rock-dev` | `secret-bunker-dev` |
| Production | `https://triad.tech` (+ `www.triad.tech`) | `https://secret-bunker.fly.dev` | `scholars-rock` | `secret-bunker` |

Things to notice about that table:

- **Production's backend URL is the raw `*.fly.dev` hostname**, not a custom `api.triad.tech` subdomain — dev uses a real custom subdomain (`dev.api.triad.tech`) but prod doesn't. This is a real (if slightly inconsistent) choice in the current setup: it works fine because nothing outside the frontend's own server-side code ever calls `RAILS_API_URL` directly, so the backend doesn't strictly need a "pretty" public hostname. If the backend ever needs to be called directly by a third party (e.g. the Doorkeeper `/oauth/token` endpoint being hit by an external MCP client, per §4.4), giving it a stable custom domain is worth doing for the same reason you'd do it for anything public: you can rotate the underlying host without every external client breaking.
- **Every Fly app gets a free `*.fly.dev` subdomain automatically** — that's always there as a fallback/internal address whether or not you ever attach a custom domain.
- `www.triad.tech` is in the CORS allowlist alongside bare `triad.tech` — a classic "don't forget the www variant" detail; DNS-level redirect handles which one the browser actually lands on, but both must be allowed if both can serve traffic.

---

## 6. Domains, DNS, and connecting your own site

This section generalizes beyond these two repos to "how do I point a domain I own at an app hosted on Fly.io (or Heroku)."

### 6.1 The concept

A domain registrar (Namecheap, Google Domains successor Squarespace, Cloudflare, etc.) lets you edit **DNS records** for a domain you own. Those records are just a public lookup table: "when something asks for `triad.tech`, tell them to go to this IP/host." Your hosting provider (Fly, Heroku, etc.) doesn't need to know anything about your registrar — it just needs you to (a) create DNS records pointing at it, and (b) tell it to expect that hostname and provision TLS for it.

### 6.2 On Fly.io

```bash
# 1. Add the app first, get Fly to tell you what DNS records to create
fly certs add triad.tech --app scholars-rock
fly certs add www.triad.tech --app scholars-rock

# 2. Fly prints back the records it needs. Typically:
#    - an A record (@) → an anycast IP Fly gives you
#    - an AAAA record (@) → the IPv6 equivalent
#    - for a subdomain like dev.triad.tech, a CNAME → scholars-rock-dev.fly.dev instead of A/AAAA

# 3. Create those records at your registrar/DNS provider, then check propagation + cert issuance:
fly certs check triad.tech --app scholars-rock
```

Fly automatically issues and renews a Let's Encrypt TLS certificate for the domain once DNS is verified — that's what `force_https = true` in `fly.toml` is enforcing traffic *into*.

For an **apex domain** (`triad.tech` with no subdomain), you're stuck using A/AAAA records because DNS forbids a CNAME at the zone apex — that's precisely why `dev.triad.tech` (a subdomain) can use a clean CNAME to `scholars-rock-dev.fly.dev`, while bare `triad.tech` needs the A/AAAA dance.

### 6.3 On Heroku (for comparison, since it's another common host)

Conceptually identical, different verb:

```bash
heroku domains:add www.example.com --app my-app
heroku domains  # prints the DNS target, e.g. something-random.herokudns.com
```

Then create a CNAME (subdomain) or use Heroku's ALIAS/ANAME support (apex domains, provider-dependent) pointing at that target. Heroku's free/hobby tiers don't include automatic TLS for custom domains the way Fly does by default — that used to require the paid "SSL" add-on or Cloudflare in front; check current Heroku pricing before assuming.

The universal pattern, regardless of host: **the platform gives you a target (an IP or a hostname), you create a DNS record pointing at it, the platform issues a cert once it can prove you control the domain (by seeing the DNS record resolve to them).**

### 6.4 Where the *app* needs to know its own domain

Getting DNS right is necessary but not sufficient — both codebases here have **application-level config that must match the domain**, independent of DNS:

- `APP_URL` (scholars-rock) — used to build the Google OAuth `redirect_uri`. If this doesn't exactly match a redirect URI registered in Google Cloud Console, Google will reject the OAuth flow outright, even though DNS and TLS are both fine.
- `FRONTEND_BASE_URL` (secret-bunker) — used to build the OAuth discovery `authorization_endpoint` (§4.4). Get this wrong and third-party OAuth clients get sent to the wrong place, or the metadata endpoint 500s (this actually happened — see the `fda9753` fix in secret-bunker's history).
- The CORS `origins` allowlist (§2.5) — a new custom domain that isn't added here will have its browser-side requests silently blocked (server-to-server SSR traffic in §4.1 is unaffected, but any direct browser→Rails call breaks).
- The Google OAuth Console's registered redirect URIs — has to be updated any time `APP_URL` changes (new domain, new environment), or login breaks with an opaque `redirect_uri_mismatch`.

**The failure mode to know**: "DNS resolves, cert is valid, site loads" and "the app actually works end-to-end" are two different milestones. A new domain/environment needs both: infrastructure-level (DNS + TLS, §6.2) *and* application-level (the four bullets above) configuration updated together.

### 6.5 Putting your own site up, step by step

If you were setting up a brand-new decoupled app like this from scratch:

1. **Backend first.** `fly launch` in the Rails repo → get a working `*.fly.dev` URL. Set `DATABASE_URL`, `RAILS_MASTER_KEY`/`SECRET_KEY_BASE`, and any JWT/session secret as `fly secrets set`.
2. **Frontend next**, pointed at that backend's `*.fly.dev` URL via an env var (`RAILS_API_URL` in this codebase's case) — you don't need custom domains yet to develop and test the integration.
3. **CORS**: add the frontend's eventual domain(s) — and `localhost:<dev-port>` for local dev — to the backend's CORS allowlist *before* you need it, not after a mystifying "network error" in the browser console.
4. **Buy/point the domain**: create the DNS records from §6.2, run `fly certs add`, wait for `fly certs check` to go green.
5. **Update app-level config to match**: `APP_URL`/`FRONTEND_BASE_URL` env vars, OAuth provider redirect URI registration, anything else that hardcodes "my own origin" — then redeploy both apps.
6. **Wire up CI/CD** so pushes to your main/dev branches auto-deploy to the matching Fly app (see the GitHub Actions pattern in §2.7/§3.4) — branch name → Fly app name → `fly.toml` file, all three need to line up.

---

## 7. API-call cheat sheet

**Frontend → Backend, authenticated GET (inside a `loader`)**
```ts
export async function loader({ request }: Route.LoaderArgs) {
  const { token } = await requireAuth(request);
  const postings = await authenticatedFetch<RailsJobPosting[]>("/api/job_postings", token);
  return { postings: postings.map(mapFromRails) };
}
```

**Frontend → Backend, authenticated mutation (inside an `action`)**
```ts
export async function action({ request }: Route.ActionArgs) {
  const { token } = await requireAuth(request);
  const formData = await request.formData();
  await authenticatedFetch("/api/job_postings", token, {
    method: "POST",
    body: JSON.stringify({ job_posting: { title: formData.get("title") } }), // snake_case keys — Rails' side
  });
  return redirect("/admin");
}
```

**Backend, protected endpoint requiring a specific permission**
```ruby
class Api::JobPostingsController < Api::ApplicationController
  before_action -> { require_permission!(Permission::CREATE_JOB_LISTING) }, only: [:create]

  def create
    return if performed?          # don't forget this — require_permission! doesn't halt on its own
    job_posting = JobPosting.create!(job_posting_params)
    render json: job_posting, status: :created
  end
end
```

**Backend, public endpoint (no auth)**
```ruby
class Api::JobPostingsController < Api::ApplicationController
  def index
    render json: JobPosting.all   # no before_action — anyone can list job postings
  end
end
```

**cURL, exercising the API exactly like the frontend does**
```bash
# Login, capture the JWT out of the response header
curl -i -X POST https://secret-bunker.fly.dev/api/auth/token \
  -H "Content-Type: application/json" \
  -d '{"user":{"email":"you@triad.tech","password":"..."}}'
# → look for `Authorization: Bearer eyJ...` in the response headers

# Use it
curl https://secret-bunker.fly.dev/api/job_postings \
  -H "Authorization: Bearer eyJ..."
```

---

## 8. Quick-reference glossary

- **SSR (server-side rendering)** — the HTML sent to the browser is fully built on the server (here: a Node process running React Router) rather than the browser downloading a blank shell and building the DOM via JS. Why it matters here: it's what lets the JWT stay server-side entirely (§3.2) — an SPA calling the API directly from the browser would have to store the token somewhere JS can read it (localStorage or a non-httpOnly cookie), which is meaningfully less safe.
- **CORS (Cross-Origin Resource Sharing)** — a browser-enforced allowlist of which origins may read the response of a cross-origin `fetch`/XHR. Irrelevant to server-to-server calls (§4.1); relevant the moment browser JS calls another origin directly.
- **Bearer token** — a credential sent as `Authorization: Bearer <token>` on every request; the server trusts whoever presents it, no cookie/session state needed server-side (mostly — see JWT revocation below).
- **JWT (JSON Web Token)** — a signed (not encrypted, by default) token encoding claims (user id, expiry) that the server can verify without a database lookup, by checking the signature against a secret/key. Its big weakness versus a server-side session: you can't cheaply "delete" one early; that's why revocation strategy matters (§2.3).
- **PKCE (Proof Key for Code Exchange)** — an OAuth extension that stops an intercepted authorization code from being redeemed by anyone but the client that started the flow, by requiring a matching secret (`code_verifier`) known only to the original requester. Mandatory in this setup's Doorkeeper config (`force_pkce`) and in OAuth 2.1 generally.
- **`*.fly.dev` domain** — the free subdomain Fly.io gives every app automatically; exists whether or not you ever attach a custom domain.
- **Release command** (Fly) — a one-off command (`bin/rails db:migrate` here) that runs once per deploy, before new machines take traffic — the standard way to run migrations safely on a platform that can run multiple machines.
- **`snake_case` vs `camelCase` boundary** — Rails/Ruby convention is snake_case (`created_at`); JS/TS convention is camelCase (`createdAt`). Since there's no shared schema between these repos, that translation is a hand-written mapper function (`mapFromRails`) on the frontend — the one place a backend field rename will silently break the frontend until someone notices.
