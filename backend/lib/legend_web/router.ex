defmodule LegendWeb.Router do
  use LegendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LegendWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/harnesses", HarnessController, :index
  end

  scope "/api" do
    pipe_through :api
    forward "/", LegendWeb.AshJsonApiRouter
  end

  # SPA catch-all: anything that isn't /api or a static asset gets index.html.
  scope "/", LegendWeb do
    get "/*path", SPAController, :index
  end
end
