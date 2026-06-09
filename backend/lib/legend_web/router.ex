defmodule LegendWeb.Router do
  use LegendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LegendWeb do
    pipe_through :api
  end

  scope "/api" do
    pipe_through :api
    forward "/", LegendWeb.AshJsonApiRouter
  end
end
