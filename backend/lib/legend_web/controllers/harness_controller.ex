defmodule LegendWeb.HarnessController do
  use LegendWeb, :controller

  def index(conn, _params) do
    data =
      for d <- Legend.Core.Harness.Registry.list() do
        %{id: d.id, name: d.name, description: d.description, kind: d.kind}
      end

    json(conn, %{data: data})
  end
end
