defmodule Legend.Core.Tunnel do
  @moduledoc """
  Makes the local backend reachable from inside a remote runtime. A tunnel is a
  per-runtime concern: each runtime declares which tunnel id it needs (sprites →
  "sprite_proxy"; a self-hosted box → WireGuard/direct; local → none). Looked up
  from `config :legend, :tunnels` by string id, like runtimes and harnesses.

  `open/1` returns the loopback base URL the agent uses (e.g. "http://127.0.0.1:7777")
  and an opaque handle passed back to `close/1`.
  """

  @type target :: map()
  @type handle :: term()

  @callback id() :: String.t()
  @callback open(target()) ::
              {:ok, %{base_url: String.t(), handle: handle()}} | {:error, String.t()}
  @callback close(handle()) :: :ok
end
