defmodule Legend.Harness.Terminal do
  @moduledoc "Contract for `:terminal`-kind harnesses: build the CLI invocation."

  @type opts :: %{optional(:env) => %{String.t() => String.t()}}

  @callback build_command(opts()) :: Legend.Runtime.CommandSpec.t()
end
