import Config
# Per-handle credentials: %{"<handle>" => "<secret>"}. Set via RELAY_HANDLES in prod
# (config/runtime.exs); empty by default so an unconfigured relay accepts nobody.
config :relay, :handles, %{}

# Listener ports. Defaults are overridden at runtime by RELAY_CARRIER_PORT /
# RELAY_DEVICE_PORT (config/runtime.exs). carrier = plaintext HTTP WS hub (TLS
# terminated upstream); device = TLS endpoint (needs RELAY_CERTFILE/RELAY_KEYFILE).
config :relay,
  carrier_port: 4900,
  device_port: 4443

if config_env() == :test, do: import_config("test.exs")
