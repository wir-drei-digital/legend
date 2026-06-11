import Config
import Dotenvy

# In a release (incl. the Burrito sidecar) RELEASE_ROOT is set; in dev/test we
# read backend/.env. Real environment variables always win over .env values.
env_dir = System.get_env("RELEASE_ROOT") || Path.expand(".")

source!([
  Path.join(env_dir, ".env"),
  System.get_env()
])

# Harness command lines (whitespace-split into cmd + args). Override per
# machine via .env, e.g. HARNESS_HERMES_CMD="hermes --profile work".
config :legend, :harness_commands,
  claude_code: env!("HARNESS_CLAUDE_CMD", :string, "claude"),
  hermes: env!("HARNESS_HERMES_CMD", :string, "hermes")

if System.get_env("PHX_SERVER") do
  config :legend, LegendWeb.Endpoint, server: true
end

if config_env() == :dev do
  config :legend, LegendWeb.Endpoint, http: [port: env!("PORT", :integer, 4000)]
end

# Allow .env to point the database somewhere else in any env except test
# (test must keep its sandbox database).
if config_env() != :test do
  case env!("DATABASE_PATH", :string, nil) do
    path when path in [nil, ""] -> :ok
    path -> config :legend, Legend.Repo, database: path
  end
end

if config_env() == :prod do
  host = env!("PHX_HOST", :string, "localhost")
  port = env!("PORT", :integer, 4807)

  config :legend, Legend.Repo,
    database: env!("DATABASE_PATH", :string),
    pool_size: 5

  config :legend, LegendWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    # Bound to loopback: right for the desktop sidecar. For a public web
    # deploy, change ip to {0, 0, 0, 0} and front it with TLS.
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: [
      "//localhost",
      "tauri://localhost",
      "http://tauri.localhost",
      "https://tauri.localhost"
    ],
    secret_key_base: env!("SECRET_KEY_BASE", :string)

  # The sidecar runs migrations on boot (no mix available in a release).
  config :legend, auto_migrate: env!("AUTO_MIGRATE", :boolean, true)
end
