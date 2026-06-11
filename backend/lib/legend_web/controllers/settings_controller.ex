defmodule LegendWeb.SettingsController do
  use LegendWeb, :controller

  alias Legend.Core.Library
  alias Legend.Core.Settings

  @library_path_key "library_path"

  def show_library_path(conn, _params) do
    json(conn, %{data: Library.root_info()})
  end

  def update_library_path(conn, %{"path" => path}) when is_binary(path) and path != "" do
    with :ok <- refuse_env_override(conn) do
      expanded = Path.expand(path)

      try do
        Library.ensure_seeded!(expanded)
        Settings.put_setting!(%{key: @library_path_key, value: expanded})
        json(conn, %{data: Library.root_info()})
      rescue
        e in RuntimeError -> send_error(conn, 400, Exception.message(e))
      end
    end
  end

  def update_library_path(conn, _params),
    do: send_error(conn, 400, "missing required param: path")

  def delete_library_path(conn, _params) do
    with :ok <- refuse_env_override(conn) do
      :ok = Settings.remove_setting(@library_path_key)
      Library.ensure_seeded!()
      json(conn, %{data: Library.root_info()})
    end
  end

  # Returns :ok, or the already-sent 409 conn (which the with-less-else returns as-is).
  defp refuse_env_override(conn) do
    if Application.get_env(:legend, :library_path) do
      send_error(conn, 409, "LIBRARY_PATH environment override is active; unset it to edit here")
    else
      :ok
    end
  end

  defp send_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
