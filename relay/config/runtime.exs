import Config

# Runtime listener config, read from the environment in dev/prod (release-safe).
# Test pins :start_listeners false and drives its own listener, so it stays out.
if config_env() != :test do
  config :relay,
    carrier_port: String.to_integer(System.get_env("RELAY_CARRIER_PORT", "4900")),
    device_port: String.to_integer(System.get_env("RELAY_DEVICE_PORT", "4443")),
    certfile: System.get_env("RELAY_CERTFILE"),
    keyfile: System.get_env("RELAY_KEYFILE")

  # RELAY_HANDLES = "handle:secret,handle2:secret2" -> %{"handle" => "secret", ...}.
  # Malformed entries (no colon / empty side) are skipped — they never crash boot.
  # IO.warn, not Logger: Logger isn't started yet at runtime.exs eval time.
  # parts: 2 so secrets may contain colons.
  handles =
    (System.get_env("RELAY_HANDLES") || "")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [handle, secret] when handle != "" and secret != "" ->
          [{handle, secret}]

        _ ->
          IO.warn("RELAY_HANDLES: skipping malformed entry #{inspect(pair)}")
          []
      end
    end)
    |> Map.new()

  config :relay, :handles, handles
end
