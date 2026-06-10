import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :legend, Legend.Repo,
  database: Path.expand("../legend_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :legend, LegendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ah8utsZhD3fwDbacHdFV9JhxgB93r3J2hAc2PdPj+KamedpC2m0J4Q98Nq3PWSmZ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
