import Config
# Per-handle credentials: %{"<handle>" => "<secret>"}. Set via RELAY_HANDLES in prod
# (config/runtime.exs); empty by default so an unconfigured relay accepts nobody.
config :relay, :handles, %{}
