defmodule Relay.Device do
  @moduledoc """
  Device-facing TLS endpoint. ThousandIsland terminates TLS; this handler resolves
  the SNI hostname to a handle, opens a mux stream on that instance's carrier, and
  splices raw cleartext bytes <-> the stream. HTTP-agnostic: the instance's Bandit
  parses the HTTP/WS on the other end.

  ## ThousandIsland 1.5 shapes used (verified against deps + a runtime spike)

    * The handler process is a `GenServer` whose state is `{socket, state}`, where
      `socket` is a `%ThousandIsland.Socket{}`. Async carrier frames therefore land in
      `handle_info/2` with that tuple (see the `:to_device` clauses).
    * `handle_close/2` (socket, state) — NOT arity 1.
    * SNI: the raw `:ssl` socket is the struct field `socket.socket`; the negotiated
      server name comes from `:ssl.connection_information(raw, [:sni_hostname])`, which
      returns `{:ok, [sni_hostname: charlist]}`.
  """
  use ThousandIsland.Handler

  @stream_open_timeout 5_000

  @spec host_to_handle(String.t() | nil) :: String.t() | nil
  def host_to_handle(nil), do: nil
  def host_to_handle(host) when is_binary(host), do: host |> String.split(".") |> List.first()

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    with handle when is_binary(handle) <- host_to_handle(sni_hostname(socket)),
         {:ok, carrier} <- Relay.Registry.lookup(handle) do
      send(carrier, {:open, self()})

      receive do
        {:stream, id} -> {:continue, %{carrier: carrier, stream_id: id}}
      after
        @stream_open_timeout -> {:close, %{}}
      end
    else
      _ -> {:close, %{}}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, %{carrier: carrier, stream_id: id} = state) do
    send(carrier, {:stream_data, id, data})
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, %{carrier: carrier, stream_id: id}) do
    send(carrier, {:stream_close, id})
  end

  def handle_close(_socket, _state), do: :ok

  # Carrier frames (instance -> device), routed to this process by Relay.Carrier.
  @impl GenServer
  def handle_info({:to_device, bytes}, {socket, state}) do
    _ = ThousandIsland.Socket.send(socket, bytes)
    {:noreply, {socket, state}}
  end

  def handle_info({:to_device_close}, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end

  @spec sni_hostname(ThousandIsland.Socket.t()) :: String.t() | nil
  defp sni_hostname(%ThousandIsland.Socket{socket: raw}) do
    case :ssl.connection_information(raw, [:sni_hostname]) do
      {:ok, [sni_hostname: host]} when is_list(host) -> List.to_string(host)
      {:ok, [sni_hostname: host]} when is_binary(host) -> host
      _ -> nil
    end
  end
end
