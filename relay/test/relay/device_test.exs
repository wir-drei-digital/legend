defmodule Relay.DeviceTest do
  use ExUnit.Case, async: false

  test "host_to_handle extracts the first DNS label" do
    assert Relay.Device.host_to_handle("laptop.relay.example.com") == "laptop"
    assert Relay.Device.host_to_handle("work.relay.example.com") == "work"
    assert Relay.Device.host_to_handle(nil) == nil
  end

  test "an unknown handle yields no carrier (connection should close)" do
    Application.put_env(:relay, :handles, %{})
    start_supervised!(Relay.Registry)
    assert :error = Relay.Registry.lookup("ghost")
  end

  test "handle_data forwards device bytes to the carrier as a stream_data frame" do
    # self() stands in for the carrier; the handler emits the Task 3 protocol message.
    state = %{carrier: self(), stream_id: 7}
    assert {:continue, ^state} = Relay.Device.handle_data("hello", :unused_socket, state)
    assert_received {:stream_data, 7, "hello"}
  end

  test "handle_close tells the carrier to close the stream" do
    state = %{carrier: self(), stream_id: 7}
    Relay.Device.handle_close(:unused_socket, state)
    assert_received {:stream_close, 7}
  end

  test "handle_close before a stream is opened is a no-op" do
    assert :ok = Relay.Device.handle_close(:unused_socket, %{})
    refute_received {:stream_close, _}
  end

  test "an instance close frame stops the handler" do
    sock_state = {:unused_socket, %{carrier: self(), stream_id: 7}}

    assert {:stop, :normal, ^sock_state} =
             Relay.Device.handle_info({:to_device_close}, sock_state)
  end
end
