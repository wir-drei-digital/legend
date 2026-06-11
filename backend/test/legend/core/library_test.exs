defmodule Legend.Core.LibraryTest do
  use ExUnit.Case, async: false

  alias Legend.Core.Library

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:legend, :library_path)
    Application.put_env(:legend, :library_path, tmp)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  test "root comes from config", %{tmp_dir: tmp} do
    assert Library.root() == tmp
  end

  test "ensure_seeded! creates conventions idempotently", %{tmp_dir: tmp} do
    assert :ok = Library.ensure_seeded!()
    assert :ok = Library.ensure_seeded!()

    for dir <- ~w(knowledge skills artifacts) do
      assert File.dir?(Path.join(tmp, dir))
      assert File.exists?(Path.join([tmp, dir, "README.md"]))
    end
  end

  test "write/read/delete round-trip through the chokepoint" do
    assert :ok = Library.write("skills/test.md", "# Test")
    assert {:ok, "# Test"} = Library.read("skills/test.md")
    assert {:ok, entries} = Library.list_tree()
    assert Enum.any?(entries, &(&1.path == "skills/test.md"))
    assert :ok = Library.delete("skills/test.md")
    assert {:error, :enoent} = Library.read("skills/test.md")
  end

  test "containment rejects escaping paths" do
    for bad <- ["../outside.txt", "/etc/passwd", "a/../../b", "skills/../../x", "~/escape.txt"] do
      assert {:error, :unsafe_path} = Library.read(bad), "expected rejection: #{bad}"
      assert {:error, :unsafe_path} = Library.write(bad, "x"), "expected rejection: #{bad}"
      assert {:error, :unsafe_path} = Library.delete(bad), "expected rejection: #{bad}"
    end

    # Interior ../ that stays inside the root is fine.
    assert :ok = Library.write("skills/a/../ok.md", "x")
    assert {:ok, "x"} = Library.read("skills/../skills/ok.md")
  end

  test "empty and root-pointing paths are rejected" do
    assert {:error, :unsafe_path} = Library.read("")
    assert {:error, :unsafe_path} = Library.read(".")
  end

  test "read rejects non-UTF-8 content as not text", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "blob.bin"), <<0xFF, 0xFE, 0x00>>)
    assert {:error, :not_text} = Library.read("blob.bin")
  end

  test "primer mentions the env var and layout" do
    assert Library.primer() =~ "LEGEND_LIBRARY"
    assert Library.primer() =~ "skills/"
  end

  test "null bytes surface as :badarg, not a crash" do
    assert {:error, :badarg} = Library.read(<<?a, 0, ?b>>)
    assert {:error, :badarg} = Library.write(<<?a, 0, ?b>>, "x")
  end
end
