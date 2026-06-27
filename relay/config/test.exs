import Config

# Tests never open the real listener ports. The gated integration test starts a
# carrier Bandit listener itself on an ephemeral port; the Registry is started
# per-test via start_supervised!. (Relay.Application also skips the Registry in
# :test — see the @start_registry? compile-time gate.)
config :relay, :start_listeners, false
