defmodule Legend.Harnesses.Hermes do
  @moduledoc "Terminal harness for the Hermes agent CLI."

  @behaviour Legend.Core.Harness
  @behaviour Legend.Core.Harness.Terminal

  alias Legend.Core.Harness.Definition
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
      args: args ++ primer_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  # Hermes' CLI primer mechanism is unknown; deliver only when the operator
  # configures a flag template (HARNESS_HERMES_PRIMER_FLAG), per the contract.
  defp primer_args(%{library: %{primer: primer}}) when is_binary(primer) and primer != "" do
    case Application.get_env(:legend, :harness_commands, [])[:hermes_primer_flag] do
      flag when is_binary(flag) and flag != "" -> [flag, primer]
      _ -> []
    end
  end

  defp primer_args(_opts), do: []

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
