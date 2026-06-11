defmodule Legend.Storage.LocalDiskTest do
  use ExUnit.Case, async: true

  alias Legend.Storage.LocalDisk

  @moduletag :tmp_dir

  test "write creates parent dirs; read round-trips", %{tmp_dir: root} do
    assert :ok = LocalDisk.write(root, "skills/git/bisect.md", "# Bisect")
    assert {:ok, "# Bisect"} = LocalDisk.read(root, "skills/git/bisect.md")
  end

  test "read of a missing file returns an error", %{tmp_dir: root} do
    assert {:error, :enoent} = LocalDisk.read(root, "nope.md")
  end

  test "list_tree returns files and dirs with metadata, sorted by path", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "knowledge/elixir.md", "x")
    :ok = LocalDisk.write(root, "artifacts/a.txt", "y")

    assert {:ok, entries} = LocalDisk.list_tree(root)

    assert Enum.map(entries, & &1.path) == [
             "artifacts",
             "artifacts/a.txt",
             "knowledge",
             "knowledge/elixir.md"
           ]

    file = Enum.find(entries, &(&1.path == "knowledge/elixir.md"))
    assert file.type == :file
    assert file.size == 1
    assert %DateTime{} = file.mtime

    dir = Enum.find(entries, &(&1.path == "artifacts"))
    assert dir.type == :dir
  end

  test "delete removes files but refuses directories", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "artifacts/tmp.txt", "x")
    assert :ok = LocalDisk.delete(root, "artifacts/tmp.txt")
    assert {:error, :enoent} = LocalDisk.read(root, "artifacts/tmp.txt")
    assert {:error, _} = LocalDisk.delete(root, "artifacts")
  end

  test "list_tree of an empty root is empty", %{tmp_dir: root} do
    assert {:ok, []} = LocalDisk.list_tree(root)
  end

  test "write overwrites existing content (last-write-wins)", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "a.md", "first")
    :ok = LocalDisk.write(root, "a.md", "second")
    assert {:ok, "second"} = LocalDisk.read(root, "a.md")
  end

  test "write accepts empty content", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "empty.md", "")
    assert {:ok, ""} = LocalDisk.read(root, "empty.md")
  end

  @tag :unix_permissions
  test "list_tree surfaces filesystem errors instead of raising", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "locked/secret.md", "x")
    locked = Path.join(root, "locked")
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod!(locked, 0o755) end)

    assert {:error, :eacces} = LocalDisk.list_tree(root)
  end
end
