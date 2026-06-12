defmodule Legend.Core.Harness do
  @moduledoc """
  An agent type Legend can run. `kind` determines the transport and UI:
  `:terminal` (PTY + xterm, implemented), `:acp` and `:native` (reserved).
  Terminal harnesses additionally implement `Legend.Core.Harness.Terminal`.

  Harnesses may export the optional setup callbacks when they need one-time
  host-machine configuration (e.g. Hermes' MCP registration). `setup/0` is
  self-describing — the UI renders only what the harness reports — and
  `apply_setup/0` is only ever invoked from an explicit user action (consent).
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

  defmodule Setup do
    @moduledoc """
    Self-describing setup state. `summary` says what Apply will do;
    `detail` carries an error explanation or manual-fix snippet;
    `restart_hint` tells the UI that running sessions need a restart
    to pick the setup up.
    """
    @derive Jason.Encoder
    defstruct status: :not_applicable, summary: "", detail: nil, restart_hint: false

    @type t :: %__MODULE__{
            status: :ok | :missing | :error | :not_applicable,
            summary: String.t(),
            detail: String.t() | nil,
            restart_hint: boolean()
          }
  end

  @callback definition() :: Definition.t()
  @callback setup() :: Setup.t()
  @callback apply_setup() :: :ok | {:error, String.t()}
  @optional_callbacks setup: 0, apply_setup: 0

  @doc "The harness's setup state; harnesses without the callback are not_applicable."
  @spec setup_for(module()) :: Setup.t()
  def setup_for(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :setup, 0) do
      module.setup()
    else
      %Setup{}
    end
  end
end
