defmodule Legend.Core.Remote.BootTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Remote

  setup do
    original = Application.get_env(:legend, LegendWeb.Endpoint)

    on_exit(fn ->
      Application.put_env(:legend, LegendWeb.Endpoint, original)
      Remote.clear()
    end)

    :ok
  end

  test "apply! is a no-op when disabled (endpoint stays loopback)" do
    before = Application.get_env(:legend, LegendWeb.Endpoint)
    :ok = Remote.Boot.apply!()
    assert Application.get_env(:legend, LegendWeb.Endpoint) == before
  end

  test "apply! binds 0.0.0.0 when enabled" do
    Remote.put_config(%{enabled: true, host: "laptop.ts.net"})
    :ok = Remote.Boot.apply!()

    http = Application.get_env(:legend, LegendWeb.Endpoint)[:http]
    assert http[:ip] == {0, 0, 0, 0}
  end
end
