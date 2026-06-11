defmodule Legend.Runtimes.LocalPty do
  @moduledoc """
  Runs an agent CLI under a true PTY on the machine the backend runs on,
  via erlexec. A small relay process receives erlexec's stdout/DOWN messages
  and forwards them to the owner in the `Legend.Runtime` message contract;
  write/resize/stop go straight to the OS process via its os_pid.
  """

  @behaviour Legend.Runtime

  alias Legend.Runtime.CommandSpec

  @start_timeout 5_000

  @impl true
  def id, do: "local_pty"

  @impl true
  def start(%CommandSpec{} = spec, opts) do
    owner = Map.fetch!(opts, :owner)

    case System.find_executable(spec.cmd) do
      nil ->
        {:error, "executable not found on PATH: #{spec.cmd}"}

      path ->
        ensure_exec_started()
        caller = self()
        ref = make_ref()

        relay =
          spawn_link(fn ->
            run_and_relay(caller, ref, owner, [path | spec.args], spec, opts)
          end)

        receive do
          {^ref, {:ok, os_pid}} -> {:ok, %{os_pid: os_pid, relay: relay}}
          {^ref, {:error, reason}} -> {:error, "failed to start #{spec.cmd}: #{inspect(reason)}"}
        after
          @start_timeout ->
            Process.unlink(relay)
            # Killing the relay makes erlexec reap the OS process it owns.
            Process.exit(relay, :kill)
            {:error, "timed out starting #{spec.cmd}"}
        end
    end
  end

  @impl true
  def write(%{os_pid: os_pid}, data) do
    :exec.send(os_pid, data)
    :ok
  end

  @impl true
  def resize(%{os_pid: os_pid}, cols, rows) do
    :exec.winsz(os_pid, rows, cols)
    :ok
  end

  @impl true
  def stop(%{os_pid: os_pid}) do
    # SIGTERM, then SIGKILL after erlexec's kill_timeout. Exit reaches the
    # owner through the relay's DOWN message.
    :exec.stop(os_pid)
    :ok
  end

  defp run_and_relay(caller, ref, owner, argv, spec, opts) do
    run_opts =
      [
        # `:stdin` opens the write pipe `:exec.send/2` targets; without it the
        # child sees EOF immediately and exits. `:pty` runs under a real PTY
        # (stderr merged into stdout); `:pty_echo` re-enables terminal echo,
        # which erlexec 2.3 disables by default.
        :stdin,
        :pty,
        :pty_echo,
        {:stdout, self()},
        :monitor,
        {:env, Map.to_list(spec.env)},
        {:winsz, {opts[:rows] || 24, opts[:cols] || 80}},
        {:kill_timeout, 5}
      ] ++ cd_opt(opts)

    case :exec.run(argv, run_opts) do
      {:ok, _pid, os_pid} ->
        send(caller, {ref, {:ok, os_pid}})
        relay_loop(owner, os_pid)

      {:error, reason} ->
        send(caller, {ref, {:error, reason}})
    end
  end

  defp cd_opt(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: [{:cd, cwd}]
  defp cd_opt(_), do: []

  defp relay_loop(owner, os_pid) do
    receive do
      {:stdout, ^os_pid, data} ->
        send(owner, {:runtime_output, data})
        relay_loop(owner, os_pid)

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        send(owner, {:runtime_exit, decode_exit(reason)})
    end
  end

  defp decode_exit(:normal), do: 0
  defp decode_exit({:exit_status, status}), do: decode_status(status)
  defp decode_exit(_other), do: nil

  defp decode_status(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, _signal, _core_dumped} -> nil
    end
  end

  defp ensure_exec_started do
    # The :erlexec app supervises the :exec server itself at boot, so this
    # normally hits :already_started. Note: erlexec tuning must therefore go
    # through `config :erlexec, ...`, not :exec.start/1 options.
    case :exec.start([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
