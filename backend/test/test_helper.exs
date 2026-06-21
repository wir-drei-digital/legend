ExUnit.start()
ExUnit.configure(exclude: [:live_sprites])
Ecto.Adapters.SQL.Sandbox.mode(Legend.Repo, :manual)
