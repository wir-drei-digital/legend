defmodule Legend.Core.Harness do
  @moduledoc """
  An agent type Legend can run. `kind` determines the transport and UI:
  `:terminal` (PTY + xterm, implemented), `:acp` and `:native` (reserved).
  Terminal harnesses additionally implement `Legend.Core.Harness.Terminal`.
  """

  defmodule Definition do
    @enforce_keys [:id, :name, :kind]
    defstruct [:id, :name, :kind, description: "", resumable: false]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            description: String.t(),
            kind: :terminal | :acp | :native,
            resumable: boolean()
          }
  end

  @callback definition() :: Definition.t()
end
