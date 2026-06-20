defmodule Legend.Core.Harness.Acp do
  @moduledoc """
  Contract for harnesses driven over the Agent Client Protocol. The harness only
  describes how to SPAWN its adapter subprocess (`io: :pipes`). The ACP wiring —
  cwd, mcpServers, instructions, session/new vs session/load — is standard
  protocol and is driven generically by the SessionServer + Acp.Connection, not
  per-harness.
  """

  @type opts :: %{optional(:env) => %{String.t() => String.t()}}
  @callback acp_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()
end
