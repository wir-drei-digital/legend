defmodule Legend.Harnesses.Hermes do
  @moduledoc "Terminal harness for the Hermes agent CLI."

  @behaviour Legend.Core.Harness
  @behaviour Legend.Core.Harness.Terminal

  alias Legend.Core.Harness.Definition
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Runtime.CommandSpec

  @impl Legend.Core.Harness
  def definition do
    %Definition{
      id: "hermes",
      name: "Hermes",
      description: "Hermes agent CLI",
      kind: :terminal
    }
  end

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:hermes, "hermes")

    %CommandSpec{
      cmd: cmd,
      args: args ++ primer_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  # Hermes' CLI primer mechanism is unknown; deliver only when the operator
  # configures a flag template (HARNESS_HERMES_PRIMER_FLAG), per the contract.
  # Hermes has no per-launch MCP flag either — registration is a one-time
  # operator entry in ~/.hermes/config.yaml that Hermes resolves from the
  # process env Legend injects (see ARCHITECTURE.md "Per-harness MCP
  # registration"):
  #
  #   mcp_servers:
  #     legend:
  #       url: ${LEGEND_MCP_URL}
  #       headers:
  #         Authorization: Bearer ${LEGEND_SESSION_TOKEN}
  defp primer_args(opts) do
    primers = Terminal.primers(opts)

    with [_ | _] <- primers,
         flag when is_binary(flag) and flag != "" <-
           Application.get_env(:legend, :harness_commands, [])[:hermes_primer_flag] do
      [flag, Enum.join(primers, "\n\n")]
    else
      _ -> []
    end
  end

  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> [text]
    end
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
