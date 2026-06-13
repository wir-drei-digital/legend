defmodule Legend.Core.Tunnel.Registry do
  @moduledoc "Looks up tunnel modules from `config :legend, :tunnels` by string id."

  @spec list() :: [module()]
  def list, do: modules()

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    Enum.find_value(modules(), :error, fn mod ->
      if mod.id() == id, do: {:ok, mod}
    end)
  end

  defp modules, do: Application.get_env(:legend, :tunnels, [])
end
