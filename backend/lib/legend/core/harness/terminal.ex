defmodule Legend.Core.Harness.Terminal do
  @moduledoc """
  Contract for `:terminal`-kind harnesses: build the CLI invocation.

  ## Library primer contract

  When opts contain `:library`, the harness SHOULD deliver `library.primer`
  through its CLI's native context mechanism (e.g. a system-prompt flag) and
  MUST NOT inject it as fake user input (no PTY injection). A harness whose
  CLI has no such mechanism delivers nothing — the platform-injected
  `LEGEND_LIBRARY` env var still applies. Plugin harnesses implement their own
  delivery against this contract.
  """

  @type library :: %{path: String.t(), primer: String.t()}
  @type opts :: %{
          optional(:env) => %{String.t() => String.t()},
          optional(:library) => library()
        }

  @callback build_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()
end
