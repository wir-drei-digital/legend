defmodule Legend.Runtimes.Sprites do
  @moduledoc """
  Runs an agent in a sprites.dev cloud sandbox: PTY over the WSS exec
  (`Legend.Sprites.Exec`), reattach-to-live on resume, teardown-on-delete.

  One sprite per session, named by the session id (idempotent create). Declares
  `library: :api` — in Spec 2a it gets no library/MCP env (the reverse tunnel
  that carries them is Spec 2b); `tunnel: "sprite_proxy"` names that future seam.

  The handle is atom-keyed `%{sprite, exec_id, relay}`; the persisted
  `runtime_ref` (string-keyed `%{"sprite", "exec_id"}`) is what `attach/2` and
  `teardown/1` receive back after a backend restart.
  """

  @behaviour Legend.Core.Runtime

  alias Legend.Core.Runtime.CommandSpec
  alias Legend.Sprites.{Client, Exec}

  @impl true
  def id, do: "sprites"

  @impl true
  def capabilities, do: %{provisions?: true, library: :api, tunnel: "sprite_proxy"}

  # Provisioning (pre-PTY): ensure the sprite exists, then run the command
  # non-interactively over the WSS exec and report stdout + exit status.
  @impl true
  def exec(%{session_id: sid}, %CommandSpec{} = spec) do
    with {:ok, _} <- ensure_sprite(sid) do
      Exec.run(sid, spec)
    end
  end

  @impl true
  def start(%CommandSpec{} = spec, opts) do
    sid = opts[:session_id] || raise "sprites runtime requires :session_id in start opts"

    with {:ok, _} <- ensure_sprite(sid),
         {:ok, pid, exec_id} <- Exec.start(sid, spec, opts) do
      {:ok, %{sprite: sid, exec_id: exec_id, relay: pid}}
    end
  end

  @impl true
  def attach(%{"sprite" => sid, "exec_id" => exec_id}, opts) do
    case Exec.attach(sid, exec_id, opts) do
      {:ok, pid} -> {:ok, %{sprite: sid, exec_id: exec_id, relay: pid}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def write(%{relay: pid}, data), do: Exec.write(pid, data)

  @impl true
  def resize(%{relay: pid}, cols, rows), do: Exec.resize(pid, cols, rows)

  @impl true
  def stop(%{relay: pid}), do: Exec.stop(pid)

  # teardown receives the persisted (string-keyed) ref on destroy; tolerate the
  # atom-keyed handle too for direct callers.
  @impl true
  def teardown(%{"sprite" => sid}), do: teardown_sprite(sid)
  def teardown(%{sprite: sid}), do: teardown_sprite(sid)

  defp teardown_sprite(sid) do
    _ = Client.delete_sprite(sid)
    :ok
  end

  # Idempotent: a session's sprite is created once and reused across exec/start.
  defp ensure_sprite(sid) do
    case Client.get_sprite(sid) do
      {:ok, _} -> {:ok, :exists}
      {:error, _} -> Client.create_sprite(sid)
    end
  end
end
