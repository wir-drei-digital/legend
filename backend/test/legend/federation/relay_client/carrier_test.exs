defmodule Legend.Federation.RelayClient.CarrierTest do
  use ExUnit.Case, async: true
  doctest Legend.Federation.RelayClient.Carrier, only: [carrier_target: 1]

  alias Legend.Federation.RelayClient.Carrier

  describe "carrier_target/1" do
    test "ws:// maps to plaintext http connect + :ws upgrade and appends /carrier" do
      assert {:http, :ws, "127.0.0.1", 4000, "/carrier"} =
               Carrier.carrier_target("ws://127.0.0.1:4000")
    end

    test "wss:// maps to https connect + :wss upgrade with default port 443" do
      assert {:https, :wss, "relay.example.com", 443, "/carrier"} =
               Carrier.carrier_target("wss://relay.example.com")
    end

    test "a base path is preserved and /carrier appended (trailing slash trimmed)" do
      assert {:https, :wss, "relay.example.com", 443, "/base/carrier"} =
               Carrier.carrier_target("wss://relay.example.com/base/")
    end

    test "an explicit port overrides the scheme default" do
      assert {:https, :wss, "relay.example.com", 8443, "/carrier"} =
               Carrier.carrier_target("wss://relay.example.com:8443")
    end
  end
end
