defmodule Legend.Core.Harness do
  @moduledoc """
  An agent type Legend can run. `transports` lists the transports the harness
  can speak, in priority order — the first entry is the default transport (a
  session's active transport lives on the session record). `:terminal`
  (PTY + xterm, implemented), `:acp` and `:native` (reserved).
  Terminal harnesses additionally implement `Legend.Core.Harness.Terminal`.

  Harnesses may export the optional setup callbacks when they need one-time
  host-machine configuration (e.g. Hermes' MCP registration). `setup/0` is
  self-describing — the UI renders only what the harness reports — and
  `apply_setup/0` is only ever invoked from an explicit user action (consent).
  """

  defmodule Definition do
    @enforce_keys [:id, :name]
    defstruct [:id, :name, description: "", resumable: false, transports: [:terminal]]

    @type transport :: :terminal | :acp | :native
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            description: String.t(),
            resumable: boolean(),
            transports: [transport()]
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
  @callback provision(transport :: Definition.transport()) ::
              %{
                detect: Legend.Core.Runtime.CommandSpec.t(),
                install: Legend.Core.Runtime.CommandSpec.t()
              }
              | nil
  @optional_callbacks setup: 0, apply_setup: 0, provision: 1

  @doc "The harness's setup state; harnesses without the callback are not_applicable."
  @spec setup_for(module()) :: Setup.t()
  def setup_for(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :setup, 0) do
      module.setup()
    else
      %Setup{}
    end
  end

  @doc "The harness's provision spec for a transport, or nil if it has no installer."
  @spec provision_for(module(), Definition.transport()) ::
          %{
            detect: Legend.Core.Runtime.CommandSpec.t(),
            install: Legend.Core.Runtime.CommandSpec.t()
          }
          | nil
  def provision_for(module, transport) do
    if Code.ensure_loaded?(module) and function_exported?(module, :provision, 1) do
      module.provision(transport)
    else
      nil
    end
  end

  @doc "Whether a harness can install itself on a provisioning runtime (transport-independent)."
  @spec provisionable?(module()) :: boolean()
  def provisionable?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :provision, 1)
  end
end
