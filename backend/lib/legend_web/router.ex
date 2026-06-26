defmodule LegendWeb.Router do
  use LegendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :device_auth do
    plug LegendWeb.DeviceAuth
  end

  # Public (NOT device-gated): health probe, agent MCP (own session token),
  # pairing redeem (the sole pre-auth human write).
  scope "/api", LegendWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/mcp", MCPController, :handle
    post "/pair", PairController, :redeem
  end

  # Device-authenticated human surfaces.
  scope "/api", LegendWeb do
    pipe_through [:api, :device_auth]

    get "/harnesses", HarnessController, :index
    post "/harnesses/:id/setup", HarnessController, :apply_setup

    get "/runtimes", RuntimeController, :index

    get "/library/tree", LibraryController, :tree
    get "/library/file", LibraryController, :show
    put "/library/file", LibraryController, :update
    delete "/library/file", LibraryController, :delete

    get "/settings/library-path", SettingsController, :show_library_path
    put "/settings/library-path", SettingsController, :update_library_path
    delete "/settings/library-path", SettingsController, :delete_library_path

    get "/settings/remote-access", RemoteController, :show
    put "/settings/remote-access", RemoteController, :update
    delete "/settings/remote-access", RemoteController, :delete

    get "/devices", DeviceController, :index
    post "/devices/pair-code", DeviceController, :create_pair_code
    delete "/devices/:id", DeviceController, :revoke
    get "/devices/audit", DeviceController, :audit
  end

  # Device-authenticated Ash JSON:API (sessions). MUST stay last under /api.
  scope "/api" do
    pipe_through [:api, :device_auth]
    forward "/", LegendWeb.AshJsonApiRouter
  end

  # SPA catch-all: anything that isn't /api or a static asset gets index.html.
  scope "/", LegendWeb do
    get "/*path", SPAController, :index
  end
end
