defmodule Legend.Core.Runtime do
  @moduledoc """
  Where and how an agent process executes. Implementations deliver output to
  the owner pid as `{:runtime_output, binary}` and termination as
  `{:runtime_exit, exit_code :: integer | nil}` (nil = killed by signal).
  """

  alias Legend.Core.Runtime.CommandSpec

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

  @type reattach_ref :: term()

  @callback capabilities() :: %{
              optional(:provisions?) => boolean(),
              optional(:library) => :path | :api,
              optional(:tunnel) => String.t() | nil
            }
  @callback exec(handle(), CommandSpec.t()) ::
              {:ok, %{stdout: binary(), status: integer()}} | {:error, String.t()}
  @callback attach(reattach_ref(), start_opts()) :: {:ok, handle()} | {:error, String.t()}
  @callback teardown(handle() | reattach_ref()) :: :ok
  @optional_callbacks capabilities: 0, exec: 2, attach: 2, teardown: 1

  @default_capabilities %{provisions?: false, library: :path, tunnel: nil}

  @doc "A runtime's capabilities, with defaults for runtimes that don't declare them."
  @spec capabilities(module()) :: %{
          provisions?: boolean(),
          library: :path | :api,
          tunnel: String.t() | nil
        }
  def capabilities(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0) do
      Map.merge(@default_capabilities, module.capabilities())
    else
      @default_capabilities
    end
  end
end
