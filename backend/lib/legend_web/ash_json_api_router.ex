defmodule LegendWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: Application.compile_env(:legend, :ash_domains, []),
    open_api: "/open_api"
end
