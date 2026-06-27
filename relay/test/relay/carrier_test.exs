defmodule Relay.CarrierTest do
  use ExUnit.Case, async: false
  alias Relay.{Carrier, Mux}
  alias Relay.Mux.Frame

  setup do
    Application.put_env(:relay, :handles, %{"laptop" => "s3cret"})
    start_supervised!(Relay.Registry)
    {:ok, state} = Carrier.init([])
    %{state: state}
  end

  test "first message registers the handle; bad secret closes", %{state: state} do
    bad = Jason.encode!(%{handle: "laptop", secret: "nope"})
    assert {:stop, _reason, _code, _state} = Carrier.handle_in({bad, opcode: :binary}, state)

    good = Jason.encode!(%{handle: "laptop", secret: "s3cret"})
    assert {:ok, registered} = Carrier.handle_in({good, opcode: :binary}, state)
    assert {:ok, _pid} = Relay.Registry.lookup("laptop")
    # the device-open path allocates a stream and pushes an OPEN frame to the instance
    assert {:push, {:binary, bin}, registered2} = Carrier.handle_info({:open, self()}, registered)
    assert {:ok, [%Frame{type: :open, stream_id: sid}], ""} = Mux.decode(bin)
    assert_received {:stream, ^sid}
    # an inbound DATA frame for that stream is routed to the device pid
    data = Mux.encode(%Frame{type: :data, stream_id: sid, payload: "hi"})
    assert {:ok, _} = Carrier.handle_in({data, opcode: :binary}, registered2)
    assert_received {:to_device, "hi"}
  end
end
