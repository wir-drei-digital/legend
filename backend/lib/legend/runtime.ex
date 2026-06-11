defmodule Legend.Runtime do
  @moduledoc """
  Where and how an agent process executes. Implementations deliver output to
  the owner pid as `{:runtime_output, binary}` and termination as
  `{:runtime_exit, exit_code :: integer | nil}` (nil = killed by signal).
  """

  alias Legend.Runtime.CommandSpec

  @typedoc "Opaque, runtime-specific handle returned by start/2."
  @type handle :: term()

  @type start_opts :: %{
          required(:owner) => pid(),
          optional(:cwd) => String.t(),
          optional(:rows) => pos_integer(),
          optional(:cols) => pos_integer()
        }

  @callback id() :: String.t()
  @callback start(CommandSpec.t(), start_opts()) :: {:ok, handle()} | {:error, String.t()}
  @callback write(handle(), binary()) :: :ok
  @callback resize(handle(), cols :: pos_integer(), rows :: pos_integer()) :: :ok
  @callback stop(handle()) :: :ok
end
