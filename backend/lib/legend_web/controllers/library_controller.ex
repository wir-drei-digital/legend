defmodule LegendWeb.LibraryController do
  use LegendWeb, :controller

  alias Legend.Core.Library

  def tree(conn, _params) do
    case Library.list_tree() do
      {:ok, entries} ->
        json(conn, %{
          data:
            for e <- entries do
              %{path: e.path, type: e.type, size: e.size, mtime: DateTime.to_iso8601(e.mtime)}
            end
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def show(conn, %{"path" => path}) do
    case Library.read(path) do
      {:ok, content} -> json(conn, %{data: %{path: path, content: content}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, _params), do: send_error(conn, 400, "missing required param: path")

  def update(conn, %{"path" => path, "content" => content}) when is_binary(content) do
    case Library.write(path, content) do
      :ok -> json(conn, %{data: %{path: path}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, _params),
    do: send_error(conn, 400, "missing or invalid params: path, content")

  def delete(conn, %{"path" => path}) do
    case Library.delete(path) do
      :ok -> json(conn, %{data: %{path: path}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, _params), do: send_error(conn, 400, "missing required param: path")

  defp error(conn, :unsafe_path), do: send_error(conn, 400, "path escapes the library root")
  defp error(conn, :not_text), do: send_error(conn, 415, "not a UTF-8 text file")
  defp error(conn, :enoent), do: send_error(conn, 404, "not found")
  # NOTE: leaks FS error atoms (e.g. :eacces) — useful and acceptable for the
  # loopback single-user PoC; replace with a generic message + server-side log
  # before any network-exposed deployment (see spec: auth before federation).
  defp error(conn, reason), do: send_error(conn, 400, "operation failed: #{inspect(reason)}")

  defp send_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
