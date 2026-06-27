ExUnit.start()
# :integration tests boot real listeners (e.g. a Bandit /carrier WS server) and
# are opt-in: `mix test --only integration`.
ExUnit.configure(exclude: [:live_sprites, :integration])
Ecto.Adapters.SQL.Sandbox.mode(Legend.Repo, :manual)
