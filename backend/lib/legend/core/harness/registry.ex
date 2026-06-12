defmodule Legend.Core.Harness.Registry do
  @moduledoc """
  Looks up harness modules from `config :legend, :harnesses`. Ids are compared
  as strings — user input never becomes an atom here.
  """

  alias Legend.Core.Harness.Definition

  @spec list() :: [Definition.t()]
  def list, do: Enum.map(modules(), & &1.definition())

  @spec entries() :: [{module(), Definition.t()}]
  def entries, do: Enum.map(modules(), &{&1, &1.definition()})

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    Enum.find_value(modules(), :error, fn mod ->
      if mod.definition().id == id, do: {:ok, mod}
    end)
  end

  defp modules, do: Application.get_env(:legend, :harnesses, [])
end
