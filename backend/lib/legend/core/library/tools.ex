defmodule Legend.Core.Library.Tools do
  @moduledoc """
  MCP tool surface for the shared library — the cloud-agent counterpart to the
  `$LEGEND_LIBRARY` filesystem a local agent gets. Pure dispatch from (tool name,
  string-keyed args) to {:ok, text} | {:error, text}; every path goes through the
  `Legend.Core.Library` containment chokepoint. The MCP controller supplies auth.
  """

  alias Legend.Core.Library

  def list do
    [
      %{
        name: "library_list",
        description: "List the shared library tree (knowledge/, skills/, artifacts/).",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "library_read",
        description: "Read a text file from the shared library.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "relative path, e.g. knowledge/x.md"}
          },
          required: ["path"]
        }
      },
      %{
        name: "library_write",
        description: "Create or overwrite a text file in the shared library.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "relative path"},
            content: %{type: "string", description: "file contents"}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "library_delete",
        description: "Delete a file from the shared library.",
        inputSchema: %{
          type: "object",
          properties: %{path: %{type: "string", description: "relative path"}},
          required: ["path"]
        }
      }
    ]
  end

  def dispatch("library_list", _args) do
    case Library.list_tree() do
      {:ok, entries} -> {:ok, format_tree(entries)}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch("library_read", %{"path" => path}) when is_binary(path) do
    case Library.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch("library_write", %{"path" => path, "content" => content})
      when is_binary(path) and is_binary(content) do
    case Library.write(path, content) do
      :ok -> {:ok, "Wrote #{path}."}
      {:ok, _} -> {:ok, "Wrote #{path}."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch("library_delete", %{"path" => path}) when is_binary(path) do
    case Library.delete(path) do
      :ok -> {:ok, "Deleted #{path}."}
      {:ok, _} -> {:ok, "Deleted #{path}."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch(name, _args), do: {:error, "unknown tool or missing required arguments: #{name}"}

  # Sanitized messages — never leak absolute paths or internals.
  defp message(:unsafe_path), do: "path escapes the library root"
  defp message(:not_text), do: "not a text file"
  defp message(:enoent), do: "no such file"
  defp message(reason) when is_atom(reason), do: "library error: #{reason}"
  defp message(reason), do: "library error: #{inspect(reason)}"

  # LocalDisk entries: %{path: string, type: :dir | :file, size: integer, mtime: DateTime}
  defp format_tree(entries) do
    entries
    |> List.wrap()
    |> Enum.map_join("\n", &format_entry/1)
  end

  defp format_entry(%{path: path, type: type}), do: "#{type}\t#{path}"
  defp format_entry(%{"path" => path, "type" => type}), do: "#{type}\t#{path}"
  defp format_entry(other), do: inspect(other)
end
