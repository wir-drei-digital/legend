defmodule Legend.Core.Runtime.Registry do
  @moduledoc "Looks up runtime modules from `config :legend, :runtimes` by string id."

  @spec list() :: [module()]
  def list, do: modules()

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    Enum.find_value(modules(), :error, fn mod ->
      if mod.id() == id, do: {:ok, mod}
    end)
  end

  defp modules, do: Application.get_env(:legend, :runtimes, [])
end
