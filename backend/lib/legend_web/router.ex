defmodule LegendWeb.Router do
  use LegendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LegendWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/harnesses", HarnessController, :index
    post "/harnesses/:id/setup", HarnessController, :apply_setup

    get "/library/tree", LibraryController, :tree
    get "/library/file", LibraryController, :show
    put "/library/file", LibraryController, :update
    delete "/library/file", LibraryController, :delete

    get "/settings/library-path", SettingsController, :show_library_path
    put "/settings/library-path", SettingsController, :update_library_path
    delete "/settings/library-path", SettingsController, :delete_library_path

    post "/mcp", MCPController, :handle
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
