defmodule Legend.Storage.LocalDisk do
  @moduledoc "Library storage on the local filesystem — the PoC adapter."

  @behaviour Legend.Core.Library.Storage

  @impl true
  def list_tree(root) do
    if File.dir?(root) do
      {:ok, root |> walk("") |> Enum.sort_by(& &1.path)}
    else
      {:ok, []}
    end
  end

  @impl true
  def read(root, rel_path), do: File.read(Path.join(root, rel_path))

  @impl true
  def write(root, rel_path, content) do
    abs = Path.join(root, rel_path)

    with :ok <- File.mkdir_p(Path.dirname(abs)) do
      File.write(abs, content)
    end
  end

  @impl true
  def delete(root, rel_path) do
    # File.rm/1 refuses directories — exactly the files-only contract.
    File.rm(Path.join(root, rel_path))
  end

  defp walk(root, rel) do
    abs = Path.join(root, rel)

    abs
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      child_rel = if rel == "", do: name, else: rel <> "/" <> name
      child_abs = Path.join(root, child_rel)
      stat = File.stat!(child_abs, time: :posix)

      entry = %{
        path: child_rel,
        type: if(stat.type == :directory, do: :dir, else: :file),
        size: stat.size,
        mtime: DateTime.from_unix!(stat.mtime)
      }

      case stat.type do
        :directory -> [entry | walk(root, child_rel)]
        _ -> [entry]
      end
    end)
  end
end
