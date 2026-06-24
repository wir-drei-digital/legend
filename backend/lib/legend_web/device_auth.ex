defmodule LegendWeb.DeviceAuth do
  @moduledoc """
  The one rule for HTTP: trusted iff loopback peer OR a valid, non-revoked device
  token. Assigns `:device` (`:local` | `%Device{}`); 401-halts otherwise. Does NOT
  bump `last_seen_at` (avoids a write per request — the socket bumps it).
  """
  import Plug.Conn

  alias LegendWeb.{DeviceToken, RemotePeer}

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      RemotePeer.loopback?(conn.remote_ip) ->
        assign(conn, :device, :local)

      true ->
        case token(conn) do
          {:ok, t} ->
            case DeviceToken.verify(t) do
              {:ok, device} -> assign(conn, :device, device)
              {:error, _} -> deny(conn)
            end

          :error ->
            deny(conn)
        end
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t] when t != "" -> {:ok, t}
      _ -> :error
    end
  end

  defp deny(conn) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: "unauthorized"})
    |> halt()
  end
end
