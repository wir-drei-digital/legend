import Config

# Runtime listener config, read from the environment in dev/prod (release-safe).
# Test pins :start_listeners false and drives its own listener, so it stays out.
if config_env() != :test do
  config :relay,
    carrier_port: String.to_integer(System.get_env("RELAY_CARRIER_PORT", "4900")),
    device_port: String.to_integer(System.get_env("RELAY_DEVICE_PORT", "4443")),
    certfile: System.get_env("RELAY_CERTFILE"),
    keyfile: System.get_env("RELAY_KEYFILE")

  # RELAY_HANDLES = "handle:secret,handle2:secret2" -> %{"handle" => "secret", ...}
  handles =
    System.get_env("RELAY_HANDLES", "")
    |> String.split(",", trim: true)
    |> Map.new(fn pair ->
      [handle, secret] = String.split(pair, ":", parts: 2)
      {handle, secret}
    end)

  config :relay, :handles, handles
end
