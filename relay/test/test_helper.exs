# Integration tests boot real listeners and are opt-in: `mix test --only integration`.
ExUnit.start(exclude: [:integration])
