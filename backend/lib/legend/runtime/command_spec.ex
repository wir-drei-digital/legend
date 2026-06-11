defmodule Legend.Runtime.CommandSpec do
  @moduledoc """
  How to invoke an agent process. Produced by a harness, consumed by a runtime.
  `io: :pty` runs under a pseudo-terminal (terminal harnesses); `:pipes` is
  reserved for ACP harnesses (plain stdio, JSON-RPC).
  """

  @enforce_keys [:cmd]
  defstruct cmd: nil, args: [], env: %{}, io: :pty

  @type t :: %__MODULE__{
          cmd: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          io: :pty | :pipes
        }
end
