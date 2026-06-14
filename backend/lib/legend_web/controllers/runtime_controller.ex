defmodule LegendWeb.RuntimeController do
  use LegendWeb, :controller

  alias Legend.Core.Runtime

  def index(conn, _params) do
    data =
      Runtime.Registry.list()
      |> Enum.map(fn mod ->
        %{id: mod.id(), capabilities: Runtime.capabilities(mod)}
      end)

    json(conn, %{data: data})
  end
end
