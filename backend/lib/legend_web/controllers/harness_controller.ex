defmodule LegendWeb.HarnessController do
  use LegendWeb, :controller

  alias Legend.Core.Harness
  alias Legend.Core.Harness.Registry

  def index(conn, _params) do
    data =
      for {mod, d} <- Registry.entries() do
        %{
          id: d.id,
          name: d.name,
          description: d.description,
          kind: d.kind,
          resumable: d.resumable,
          setup: Harness.setup_for(mod)
        }
      end

    json(conn, %{data: data})
  end

  def apply_setup(conn, %{"id" => id}) do
    with {:ok, mod} <- Registry.fetch(id),
         :ok <- ensure_setup_capable(mod),
         :ok <- mod.apply_setup() do
      json(conn, %{data: Harness.setup_for(mod)})
    else
      :error ->
        conn |> put_status(404) |> json(%{error: "unknown harness: #{id}"})

      {:error, message} ->
        conn |> put_status(422) |> json(%{error: message})
    end
  end

  defp ensure_setup_capable(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :apply_setup, 0) do
      :ok
    else
      {:error, "harness has no setup"}
    end
  end
end
